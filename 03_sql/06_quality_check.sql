-- =====================================================================
-- core 데이터 품질 점검 (MySQL 8.0)
-- 실행 순서: 05_transform_core.sql → generate_store_data.py 다음
-- 구성
--   결과 1: 점검 요약 (규칙별 위반 건수와 예상 결과)
--   결과 2: [Q-13] 매장재고와 재고변동이력 불일치 상세 → 가상 데이터 주입 목록과 대조
--   결과 3: [Q-12] 결제금액과 주문금액 불일치 상세
--   결과 4: [Q-17] 실사조정 사유별 복원 비율 (조정 사유 데이터의 정확성)
-- 원칙: 적재 단계에서 걸러내지 않은 원천 문제를 여기서 검출해 보고한다 (D-020)
-- 코드값 목록은 표준 사전의 표준코드 시트를 따른다.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 결과 1. 점검 요약
-- ---------------------------------------------------------------------
SELECT chk_id, dimension, rule_desc, violation_cnt, expected
FROM (
    -- ===== 완전성: 조건부 필수값 =====
    SELECT 'Q-01' AS chk_id, '완전성' AS dimension,
           '온라인 채널(택배·픽업·매장출고) 주문에 회원이 없음 (D-018)' AS rule_desc,
           (SELECT COUNT(*) FROM core.ord WHERE sale_chnl_cd <> 'STORE' AND mbr_id IS NULL) AS violation_cnt,
           '0' AS expected
    UNION ALL
    SELECT 'Q-02', '완전성', '매장 채널(매장판매·픽업·매장출고) 주문에 출고매장이 없음 (D-017)',
           (SELECT COUNT(*) FROM core.ord WHERE sale_chnl_cd <> 'PARCEL' AND str_id IS NULL), '0'
    UNION ALL
    SELECT 'Q-03', '완전성', '택배배송 주문에 출고매장이 있음 (D-017)',
           (SELECT COUNT(*) FROM core.ord WHERE sale_chnl_cd = 'PARCEL' AND str_id IS NOT NULL), '0'
    UNION ALL
    SELECT 'Q-04', '완전성', '실사조정인데 조정사유가 없거나, 실사조정이 아닌데 조정사유가 있음 (D-007)',
           (SELECT COUNT(*) FROM core.stck_chg_hist
             WHERE (chg_type_cd = 'ADJ' AND adj_rsn_cd IS NULL)
                OR (chg_type_cd <> 'ADJ' AND adj_rsn_cd IS NOT NULL)), '0'
    UNION ALL
    SELECT 'Q-05', '완전성', '수령완료 상태인데 수령완료일시가 없음',
           (SELECT COUNT(*) FROM core.ord WHERE ord_stat_cd = 'RECEIVED' AND rcv_cmpl_dtm IS NULL),
           '원천 확인'
    UNION ALL
    SELECT 'Q-06', '완전성', '취소 상태인데 취소일시가 없음',
           (SELECT COUNT(*) FROM core.ord WHERE ord_stat_cd = 'CANCELED' AND cncl_dtm IS NULL),
           '원천 한계 (Olist에 취소 시각 없음)'

    -- ===== 유효성: 코드값·값 범위 =====
    UNION ALL
    SELECT 'Q-07', '유효성', '표준코드에 없는 코드값 (주문·결제·재고·회원 코드 전체)',
           (SELECT COUNT(*) FROM core.ord WHERE sale_chnl_cd NOT IN ('STORE','PARCEL','STORE_SHIP','PICKUP')
                                             OR ord_stat_cd NOT IN ('ORDERED','PAID','PACKED','SHIPPED','RECEIVED','CANCELED'))
         + (SELECT COUNT(*) FROM core.pay WHERE pay_mthd_cd NOT IN ('CREDIT','DEBIT','BANK_SLIP','VOUCHER','CASH'))
         + (SELECT COUNT(*) FROM core.str_stck WHERE stck_stat_cd NOT IN ('AVAIL','ORD_HOLD','TESTER'))
         + (SELECT COUNT(*) FROM core.stck_chg_hist
             WHERE stck_stat_cd NOT IN ('AVAIL','ORD_HOLD','TESTER')
                OR chg_type_cd NOT IN ('IN','SALE','ORD_ALLOC','ORD_RCV','ORD_CNCL','RETURN','DISPOSE','ADJ','TESTER_IN','TESTER_OUT')
                OR (adj_rsn_cd IS NOT NULL AND adj_rsn_cd NOT IN ('THEFT','DAMAGE','POS_ERR','UNKNOWN','FOUND')))
         + (SELECT COUNT(*) FROM core.mbr WHERE join_chnl_cd NOT IN ('ONLINE','STORE')),
           '원천 확인 (결제수단 not_defined)'
    UNION ALL
    SELECT 'Q-08', '유효성', '결제금액 또는 판매단가가 0 이하',
           (SELECT COUNT(*) FROM core.pay WHERE pay_amt <= 0)
         + (SELECT COUNT(*) FROM core.ord_dtl WHERE sale_uprc <= 0),
           '원천 확인'

    -- ===== 관계 무결성: 카디널리티 (FK는 DB가 보장하므로 1:N의 필수 쪽을 점검) =====
    UNION ALL
    SELECT 'Q-09', '관계', '주문상세가 하나도 없는 주문 (주문 1 : 주문상세 1..N 위반)',
           (SELECT COUNT(*) FROM core.ord o WHERE NOT EXISTS (SELECT 1 FROM core.ord_dtl d WHERE d.ord_id = o.ord_id)),
           '0'
    UNION ALL
    SELECT 'Q-10', '관계', '결제가 하나도 없는 주문',
           (SELECT COUNT(*) FROM core.ord o WHERE NOT EXISTS (SELECT 1 FROM core.pay p WHERE p.ord_id = o.ord_id)),
           '1 (원천 품질 이슈 4번)'

    -- ===== 유일성 =====
    UNION ALL
    SELECT 'Q-11', '유일성', '한 주문에 같은 상품옵션·단가의 주문상세가 여러 행 (수량 집계 누락, D-013)',
           (SELECT COUNT(*) FROM (SELECT ord_id, prd_opt_id, sale_uprc FROM core.ord_dtl
                                  GROUP BY ord_id, prd_opt_id, sale_uprc HAVING COUNT(*) > 1) x),
           '0'

    -- ===== 정합성: 값 사이의 관계 =====
    UNION ALL
    SELECT 'Q-12', '정합성', '결제금액 합계와 주문금액(판매단가 × 수량 + 배송비) 합계가 0.01 이상 다름',
           (SELECT COUNT(*) FROM (
                SELECT o.ord_id
                FROM core.ord o
                JOIN (SELECT ord_id, SUM(sale_uprc * ord_qty + ship_fee) AS amt FROM core.ord_dtl GROUP BY ord_id) d ON d.ord_id = o.ord_id
                JOIN (SELECT ord_id, SUM(pay_amt) AS amt FROM core.pay GROUP BY ord_id) p ON p.ord_id = o.ord_id
                WHERE ABS(d.amt - p.amt) >= 0.01) x),
           '원천 확인 (원천 품질 이슈 3번)'
    UNION ALL
    SELECT 'Q-13', '정합성', '매장재고 수량 ≠ 재고변동이력 누적 합계 (D-002)',
           (SELECT COUNT(*)
              FROM core.str_stck s
              LEFT JOIN (SELECT str_id, prd_opt_id, stck_stat_cd, SUM(chg_qty) AS qty
                           FROM core.stck_chg_hist GROUP BY str_id, prd_opt_id, stck_stat_cd) h
                ON h.str_id = s.str_id AND h.prd_opt_id = s.prd_opt_id AND h.stck_stat_cd = s.stck_stat_cd
             WHERE s.stck_qty <> COALESCE(h.qty, 0)),
           '5 (가상 데이터 의도적 주입)'
    UNION ALL
    SELECT 'Q-14', '정합성', '매장재고 수량이 음수',
           (SELECT COUNT(*) FROM core.str_stck WHERE stck_qty < 0), '0'
    UNION ALL
    SELECT 'Q-15', '정합성', '일시 순서가 맞지 않는 주문 (주문일시보다 이른 처리일시, 택배인계보다 이른 수령)',
           (SELECT COUNT(*) FROM core.ord
             WHERE pay_aprv_dtm  < ord_dtm
                OR pack_cmpl_dtm < ord_dtm
                OR prcl_hndv_dtm < ord_dtm
                OR rcv_cmpl_dtm  < ord_dtm
                OR rcv_cmpl_dtm  < prcl_hndv_dtm),
           '원천 확인'
    UNION ALL
    SELECT 'Q-16', '정합성', '취소된 픽업·매장출고 주문인데 재고 복원(주문취소복원) 이력이 없음 (D-006)',
           (SELECT COUNT(*) FROM core.ord o
             WHERE o.sale_chnl_cd IN ('PICKUP','STORE_SHIP') AND o.ord_stat_cd = 'CANCELED'
               AND NOT EXISTS (SELECT 1 FROM core.stck_chg_hist h
                                WHERE h.ord_id = o.ord_id AND h.chg_type_cd = 'ORD_CNCL')),
           '0'

    -- ===== 정확성: 값이 현실을 반영하는가 =====
    UNION ALL
    SELECT 'Q-17', '정확성', '실사조정 차감 후 2일 안에 같은 매장·상품이 증가 조정된 건 (조정 사유가 틀렸을 가능성, D-008)',
           (SELECT COUNT(*) FROM core.stck_chg_hist a
             WHERE a.chg_type_cd = 'ADJ' AND a.chg_qty < 0
               AND EXISTS (SELECT 1 FROM core.stck_chg_hist b
                            WHERE b.str_id = a.str_id AND b.prd_opt_id = a.prd_opt_id
                              AND b.chg_type_cd = 'ADJ' AND b.chg_qty > 0
                              AND b.chg_dtm >  a.chg_dtm
                              AND b.chg_dtm <= a.chg_dtm + INTERVAL 2 DAY)),
           '결과 4에서 비율로 해석'
) t
ORDER BY chk_id;

-- ---------------------------------------------------------------------
-- 결과 2. [Q-13] 불일치 상세: generate_store_data.py 출력의 주입 목록과 같아야 한다
-- ---------------------------------------------------------------------
SELECT s.str_id, s.prd_opt_id, s.stck_stat_cd,
       s.stck_qty            AS stck_qty,
       COALESCE(h.qty, 0)    AS hist_qty,
       s.stck_qty - COALESCE(h.qty, 0) AS diff
FROM core.str_stck s
LEFT JOIN (SELECT str_id, prd_opt_id, stck_stat_cd, SUM(chg_qty) AS qty
             FROM core.stck_chg_hist GROUP BY str_id, prd_opt_id, stck_stat_cd) h
  ON h.str_id = s.str_id AND h.prd_opt_id = s.prd_opt_id AND h.stck_stat_cd = s.stck_stat_cd
WHERE s.stck_qty <> COALESCE(h.qty, 0)
ORDER BY s.str_id, s.prd_opt_id;

-- ---------------------------------------------------------------------
-- 결과 3. [Q-12] 금액 불일치 상세: 채널별로 나눠 원천 문제인지 확인
-- ---------------------------------------------------------------------
SELECT o.sale_chnl_cd, o.src_ord_no, o.ord_id,
       d.amt AS ord_amt, p.amt AS pay_amt, p.amt - d.amt AS diff
FROM core.ord o
JOIN (SELECT ord_id, SUM(sale_uprc * ord_qty + ship_fee) AS amt FROM core.ord_dtl GROUP BY ord_id) d ON d.ord_id = o.ord_id
JOIN (SELECT ord_id, SUM(pay_amt) AS amt FROM core.pay GROUP BY ord_id) p ON p.ord_id = o.ord_id
WHERE ABS(d.amt - p.amt) >= 0.01
ORDER BY ABS(p.amt - d.amt) DESC;

-- ---------------------------------------------------------------------
-- 결과 4. [Q-17] 실사조정 사유별 2일 내 복원 비율
--   복원 비율이 높은 사유는 '실제로는 못 찾은 것'을 다른 사유로 기록했을 가능성이 크다.
--   (가상 데이터 기반이므로 발견이 아니라 점검 방법의 시연, D-008)
-- ---------------------------------------------------------------------
SELECT a.adj_rsn_cd,
       COUNT(*) AS minus_cnt,
       SUM(EXISTS (SELECT 1 FROM core.stck_chg_hist b
                    WHERE b.str_id = a.str_id AND b.prd_opt_id = a.prd_opt_id
                      AND b.chg_type_cd = 'ADJ' AND b.chg_qty > 0
                      AND b.chg_dtm >  a.chg_dtm
                      AND b.chg_dtm <= a.chg_dtm + INTERVAL 2 DAY)) AS restored_2d,
       ROUND(100 * SUM(EXISTS (SELECT 1 FROM core.stck_chg_hist b
                    WHERE b.str_id = a.str_id AND b.prd_opt_id = a.prd_opt_id
                      AND b.chg_type_cd = 'ADJ' AND b.chg_qty > 0
                      AND b.chg_dtm >  a.chg_dtm
                      AND b.chg_dtm <= a.chg_dtm + INTERVAL 2 DAY)) / COUNT(*), 1) AS restored_pct
FROM core.stck_chg_hist a
WHERE a.chg_type_cd = 'ADJ' AND a.chg_qty < 0
GROUP BY a.adj_rsn_cd
ORDER BY restored_pct DESC;
