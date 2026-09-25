-- =====================================================================
-- 업무 SQL (MySQL 8.0)
-- 목적: 설계한 모델로 실제 업무 질문에 답할 수 있는지 보여준다.
-- 실행 순서: 05_transform_core.sql → generate_store_data.py 다음
-- 매장 채널 데이터는 가상 데이터이므로, 결과는 발견이 아니라 모델 활용의 시연이다.
-- =====================================================================

-- ---------------------------------------------------------------------
-- B-01. 채널별 월 매출 (온·오프라인 통합 조회)
-- 질문: 매장판매·택배배송·매장출고배송·매장픽업의 월별 매출 구성은 어떤가?
-- 포인트: 주문을 채널코드 하나로 통합했기 때문에(D-017) UNION 없이 한 번에 집계된다.
--         매출은 판매단가 × 수량 기준(배송비 제외), 취소 주문 제외.
-- ---------------------------------------------------------------------
SELECT DATE_FORMAT(o.ord_dtm, '%Y-%m')                                            AS ym,
       SUM(CASE WHEN o.sale_chnl_cd = 'STORE'      THEN d.sale_uprc * d.ord_qty END) AS store_amt,
       SUM(CASE WHEN o.sale_chnl_cd = 'PARCEL'     THEN d.sale_uprc * d.ord_qty END) AS parcel_amt,
       SUM(CASE WHEN o.sale_chnl_cd = 'STORE_SHIP' THEN d.sale_uprc * d.ord_qty END) AS store_ship_amt,
       SUM(CASE WHEN o.sale_chnl_cd = 'PICKUP'     THEN d.sale_uprc * d.ord_qty END) AS pickup_amt,
       SUM(d.sale_uprc * d.ord_qty)                                                  AS total_amt,
       ROUND(100 * SUM(CASE WHEN o.sale_chnl_cd <> 'STORE' THEN d.sale_uprc * d.ord_qty END)
             / SUM(d.sale_uprc * d.ord_qty), 1)                                      AS online_pct
FROM core.ord o
JOIN core.ord_dtl d ON d.ord_id = o.ord_id
WHERE o.ord_stat_cd <> 'CANCELED'
  AND o.ord_dtm >= '2017-01-01'
GROUP BY DATE_FORMAT(o.ord_dtm, '%Y-%m')
ORDER BY ym;

-- ---------------------------------------------------------------------
-- B-02. 취소 봉투 확인 목록 (D-006, 프로젝트의 출발점이 된 현장 문제)
-- 질문: 지금 전산에는 가용 재고로 보이지만, 실제로는 취소된 포장 봉투 안에 있을 수 있는 상품은?
-- 규칙: 포장완료 후 취소되었고, 취소 후 2일이 지나지 않은 주문의 상품
-- 사용법: @base_dtm을 확인하려는 시각으로 바꿔 실행 (예: 할인 행사 기간 중 개점 직후)
-- 포인트: 재진열 입력 없이, 이미 기록되는 포장완료일시·취소일시만으로 안내한다.
--         기준 시각의 가용재고는 재고변동이력 누적으로 계산한다 (이력 테이블이 있어서 가능한 조회).
-- ---------------------------------------------------------------------
SET @base_dtm = '2018-05-24 10:00:00';

SELECT s.str_nm,
       p.prd_nm,
       b.bag_qty,                                                      -- 봉투에 있을 수 있는 수량
       (SELECT COALESCE(SUM(h.chg_qty), 0) FROM core.stck_chg_hist h
         WHERE h.str_id = b.str_id AND h.prd_opt_id = b.prd_opt_id
           AND h.stck_stat_cd = 'AVAIL' AND h.chg_dtm <= @base_dtm) AS avail_qty_at_base,   -- 전산 가용재고
       b.ord_ids,
       b.last_cncl_dtm,
       b.after_close_yn                                                -- 영업 마감 후 취소 포함 여부
FROM (
    SELECT o.str_id, d.prd_opt_id,
           SUM(d.ord_qty)                                  AS bag_qty,
           GROUP_CONCAT(o.ord_id ORDER BY o.cncl_dtm)      AS ord_ids,
           MAX(o.cncl_dtm)                                 AS last_cncl_dtm,
           MAX(CASE WHEN HOUR(o.cncl_dtm) >= 22 OR HOUR(o.cncl_dtm) < 10 THEN 'Y' ELSE 'N' END) AS after_close_yn
    FROM core.ord o
    JOIN core.ord_dtl d ON d.ord_id = o.ord_id
    WHERE o.sale_chnl_cd IN ('PICKUP', 'STORE_SHIP')
      AND o.pack_cmpl_dtm IS NOT NULL                              -- 포장까지 끝난 주문만 (포장 전 취소는 진열대에 있음)
      AND o.cncl_dtm >  @base_dtm - INTERVAL 2 DAY
      AND o.cncl_dtm <= @base_dtm
    GROUP BY o.str_id, d.prd_opt_id
) b
JOIN core.str     s  ON s.str_id      = b.str_id
JOIN core.prd_opt po ON po.prd_opt_id = b.prd_opt_id
JOIN core.prd     p  ON p.prd_id      = po.prd_id
ORDER BY s.str_nm, b.last_cncl_dtm;

-- ---------------------------------------------------------------------
-- B-03. 할인 행사 기간과 평상시의 포장완료 후 취소 비교
-- 질문: 온라인 주문이 몰리는 행사 기간에 '취소 봉투'가 얼마나 늘어나는가?
-- 포인트: 행사 기간에 B-02 같은 확인 목록이 왜 필요한지 수치로 보여준다.
-- ---------------------------------------------------------------------
SELECT period_nm,
       COUNT(DISTINCT DATE(ord_dtm))                                        AS days,
       COUNT(*)                                                             AS online_ord_cnt,
       SUM(pack_cmpl_dtm IS NOT NULL AND cncl_dtm IS NOT NULL)              AS packed_cncl_cnt,
       ROUND(SUM(pack_cmpl_dtm IS NOT NULL AND cncl_dtm IS NOT NULL)
             / COUNT(DISTINCT DATE(ord_dtm)), 2)                            AS packed_cncl_per_day,
       ROUND(100 * SUM(pack_cmpl_dtm IS NOT NULL AND cncl_dtm IS NOT NULL)
             / SUM(pack_cmpl_dtm IS NOT NULL), 1)                           AS packed_cncl_pct
FROM (
    SELECT o.*,
           CASE WHEN DATE(o.ord_dtm) BETWEEN '2017-11-20' AND '2017-11-26' THEN '행사 1 (2017-11)'
                WHEN DATE(o.ord_dtm) BETWEEN '2018-05-21' AND '2018-05-27' THEN '행사 2 (2018-05)'
                ELSE '평상시' END AS period_nm
    FROM core.ord o
    WHERE o.sale_chnl_cd IN ('PICKUP', 'STORE_SHIP')
) x
GROUP BY period_nm
ORDER BY period_nm;

-- ---------------------------------------------------------------------
-- B-04. 매장별 실사조정 현황 (전산·실물 차이의 원인 구성)
-- 질문: 매장마다 재고 차이가 어떤 사유로, 얼마나 발생했고, 그중 실제로는 찾은 것이 얼마인가?
-- 포인트: 조정 사유별 건수와 2일 내 복원을 함께 보면, 사유 데이터를 그대로 믿어도 되는지 판단할 수 있다 (D-007, D-008).
-- ---------------------------------------------------------------------
SELECT s.str_nm,
       COUNT(*)                                             AS minus_adj_cnt,
       SUM(a.adj_rsn_cd = 'POS_ERR')                        AS pos_err,
       SUM(a.adj_rsn_cd = 'THEFT')                          AS theft,
       SUM(a.adj_rsn_cd = 'DAMAGE')                         AS damage,
       SUM(a.adj_rsn_cd = 'UNKNOWN')                        AS unknown,
       SUM(EXISTS (SELECT 1 FROM core.stck_chg_hist r
                    WHERE r.str_id = a.str_id AND r.prd_opt_id = a.prd_opt_id
                      AND r.chg_type_cd = 'ADJ' AND r.chg_qty > 0
                      AND r.chg_dtm > a.chg_dtm AND r.chg_dtm <= a.chg_dtm + INTERVAL 2 DAY)) AS found_in_2d,
       -- 2일 안에 찾은 건을 빼면 실제 손실로 볼 수 있는 건수
       COUNT(*) - SUM(EXISTS (SELECT 1 FROM core.stck_chg_hist r
                    WHERE r.str_id = a.str_id AND r.prd_opt_id = a.prd_opt_id
                      AND r.chg_type_cd = 'ADJ' AND r.chg_qty > 0
                      AND r.chg_dtm > a.chg_dtm AND r.chg_dtm <= a.chg_dtm + INTERVAL 2 DAY)) AS est_real_loss
FROM core.stck_chg_hist a
JOIN core.str s ON s.str_id = a.str_id
WHERE a.chg_type_cd = 'ADJ' AND a.chg_qty < 0
GROUP BY s.str_nm
ORDER BY minus_adj_cnt DESC;

-- ---------------------------------------------------------------------
-- B-05. 옴니채널 회원 (한 회원이 이용한 채널 조합)
-- 질문: 온라인 택배만 쓰는 회원과, 매장 채널(픽업·매장출고)까지 함께 쓰는 회원은 얼마나 되는가?
-- 포인트: 회원을 customer_unique_id 기준 한 사람으로 통합했기 때문에(D-011) 채널을 넘나드는 이용을 셀 수 있다.
--         customer_id를 회원으로 썼다면 주문마다 다른 회원이 되어 이 집계가 불가능하다.
-- ---------------------------------------------------------------------
SELECT chnl_combo,
       COUNT(*)                                        AS mbr_cnt,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS mbr_pct,
       ROUND(AVG(ord_cnt), 2)                          AS avg_ord_cnt
FROM (
    SELECT o.mbr_id,
           GROUP_CONCAT(DISTINCT o.sale_chnl_cd ORDER BY o.sale_chnl_cd SEPARATOR ' + ') AS chnl_combo,
           COUNT(*) AS ord_cnt
    FROM core.ord o
    WHERE o.mbr_id IS NOT NULL AND o.ord_stat_cd <> 'CANCELED'
    GROUP BY o.mbr_id
) m
GROUP BY chnl_combo
ORDER BY mbr_cnt DESC;
