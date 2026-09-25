-- =====================================================================
-- stg → core 변환 (MySQL 8.0)
-- 기준: mapping_spec.xlsx (적용 계층 = core 인 규칙)
-- core의 역할: 설계한 모델 구조로 재구성
--   대체키 생성, 수량 집계, 다른 테이블 조회(회원·주소), 가상 기준정보(카테고리·브랜드) 생성
-- 실행 순서: 04_transform_stg.sql 다음, 가상 데이터(매장·재고·매장 주문) 생성 전
-- 주의: core 전체를 비우고 다시 적재한다. 가상 데이터를 넣은 뒤 재실행하면 가상 데이터도 지워진다.
-- 무작위 배정은 CRC32(원천번호) 기반이라 몇 번을 다시 실행해도 같은 결과가 나온다(재현성).
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE core.stck_chg_hist;
TRUNCATE TABLE core.str_stck;
TRUNCATE TABLE core.pay;
TRUNCATE TABLE core.ord_dtl;
TRUNCATE TABLE core.ord;
TRUNCATE TABLE core.prd_opt;
TRUNCATE TABLE core.prd;
TRUNCATE TABLE core.str;
TRUNCATE TABLE core.mbr;
TRUNCATE TABLE core.brnd;
TRUNCATE TABLE core.ctgr;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 1. 카테고리: 대분류 1개(원천) + 중분류 6개(가상) (D-024)
-- ---------------------------------------------------------------------
INSERT INTO core.ctgr (uppr_ctgr_id, ctgr_nm, ctgr_lvl, src_ctgr_cd)
VALUES (NULL, '헬스·뷰티', 1, 'beleza_saude');

INSERT INTO core.ctgr (uppr_ctgr_id, ctgr_nm, ctgr_lvl, src_ctgr_cd)
SELECT top.ctgr_id, sub.nm, 2, NULL
FROM core.ctgr top
CROSS JOIN (
    SELECT 1 AS seq, '스킨케어' AS nm UNION ALL
    SELECT 2, '메이크업'           UNION ALL
    SELECT 3, '헤어케어'           UNION ALL
    SELECT 4, '바디케어'           UNION ALL
    SELECT 5, '향수'               UNION ALL
    SELECT 6, '건강기능식품'
) sub
WHERE top.src_ctgr_cd = 'beleza_saude'
ORDER BY sub.seq;

-- ---------------------------------------------------------------------
-- 2. 브랜드: 가상 20개 (D-015). 실제 브랜드와 혼동되지 않도록 번호형 이름 사용
-- ---------------------------------------------------------------------
INSERT INTO core.brnd (brnd_nm)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 20)
SELECT CONCAT('브랜드', LPAD(i, 2, '0')) FROM n ORDER BY i;

-- ---------------------------------------------------------------------
-- 3. 상품: 중분류·브랜드는 원천상품번호의 CRC32 값으로 배정 (D-015, D-024)
--    정가가 없는(판매 이력 없는) 상품은 제외 → stg 점검 (3)에서 건수 확인
-- ---------------------------------------------------------------------
INSERT INTO core.prd (ctgr_id, brnd_id, src_prd_no, prd_nm, lprc, wt, len, hgt, wdt)
WITH c AS (
    SELECT ctgr_id, ctgr_nm,
           ROW_NUMBER() OVER (ORDER BY ctgr_id) - 1 AS k,   -- 0부터 번호
           COUNT(*) OVER () AS cnt
    FROM core.ctgr WHERE ctgr_lvl = 2
), b AS (
    SELECT brnd_id, brnd_nm,
           ROW_NUMBER() OVER (ORDER BY brnd_id) - 1 AS k,
           COUNT(*) OVER () AS cnt
    FROM core.brnd
), p AS (
    SELECT s.*, ROW_NUMBER() OVER (ORDER BY s.src_prd_no) AS rn
    FROM stg.olist_products s
    WHERE s.lprc IS NOT NULL
)
SELECT c.ctgr_id, b.brnd_id, p.src_prd_no,
       CONCAT(b.brnd_nm, ' ', c.ctgr_nm, ' ', LPAD(p.rn, 4, '0')),   -- 예: 브랜드03 스킨케어 0012
       p.lprc, p.wt, p.len, p.hgt, p.wdt
FROM p
JOIN c ON c.k = CRC32(p.src_prd_no) % c.cnt
JOIN b ON b.k = CRC32(CONCAT('brand:', p.src_prd_no)) % b.cnt
ORDER BY p.rn;

-- ---------------------------------------------------------------------
-- 4. 상품옵션: 원천 상품당 기본 옵션 1개 (D-015)
-- ---------------------------------------------------------------------
INSERT INTO core.prd_opt (prd_id, opt_nm)
SELECT prd_id, '기본' FROM core.prd ORDER BY prd_id;

-- ---------------------------------------------------------------------
-- 5. 회원: 이관 대상 주문을 한 사람(customer_unique_id)만 (D-011)
--    가입일시 = 원천 전체 주문 중 최초 주문일시 (D-023)
--    주소 = 원천 전체 주문 중 가장 최근 주문의 주소 (D-011)
-- ---------------------------------------------------------------------
INSERT INTO core.mbr (src_mbr_no, join_chnl_cd, join_dtm, zip_no, city_nm, st_nm)
WITH o AS (
    SELECT c.src_mbr_no, o.src_ord_no, o.ord_dtm, o.trgt_yn, c.zip_no, c.city_nm, c.st_nm
    FROM stg.olist_orders o
    JOIN stg.olist_customers c ON c.src_cust_no = o.src_cust_no
), r AS (
    SELECT o.*,
           ROW_NUMBER() OVER (PARTITION BY src_mbr_no ORDER BY ord_dtm DESC, src_ord_no) AS rn,  -- 1 = 최근 주문
           MIN(ord_dtm)  OVER (PARTITION BY src_mbr_no) AS first_ord_dtm,
           MAX(trgt_yn)  OVER (PARTITION BY src_mbr_no) AS has_trgt                              -- 'Y' > 'N'
    FROM o
)
SELECT src_mbr_no, 'ONLINE', first_ord_dtm, zip_no, city_nm, st_nm
FROM r
WHERE rn = 1 AND has_trgt = 'Y'
ORDER BY first_ord_dtm, src_mbr_no;

-- ---------------------------------------------------------------------
-- 6. 주문: 이관 대상만. 택배배송 채널, 출고매장 없음 (D-017)
--    회원·배송지는 LEFT JOIN: 연결이 안 되는 주문도 적재한 뒤 품질 점검에서 검출 (D-020)
-- ---------------------------------------------------------------------
INSERT INTO core.ord (mbr_id, str_id, src_ord_no, sale_chnl_cd, ord_stat_cd, ord_dtm,
                      pay_aprv_dtm, pack_cmpl_dtm, prcl_hndv_dtm, rcv_cmpl_dtm, est_rcv_dt, cncl_dtm,
                      shpto_zip_no, shpto_city_nm, shpto_st_nm)
SELECT m.mbr_id, NULL, o.src_ord_no, 'PARCEL', o.ord_stat_cd, o.ord_dtm,
       o.pay_aprv_dtm, NULL, o.prcl_hndv_dtm, o.rcv_cmpl_dtm, o.est_rcv_dt,
       NULL,                                   -- 원천에 취소 시각 없음 (한계)
       c.zip_no, c.city_nm, c.st_nm            -- 주문 당시 주소
FROM stg.olist_orders o
LEFT JOIN stg.olist_customers c ON c.src_cust_no = o.src_cust_no
LEFT JOIN core.mbr m            ON m.src_mbr_no  = c.src_mbr_no
WHERE o.trgt_yn = 'Y'
ORDER BY o.ord_dtm, o.src_ord_no;

-- ---------------------------------------------------------------------
-- 7. 주문상세: (주문, 상품, 단가)별로 원천 반복 행을 묶어 수량으로 집계 (D-013)
--    순번은 원천 품목순번이 가장 작은 순서로 주문 안에서 다시 매김
-- ---------------------------------------------------------------------
INSERT INTO core.ord_dtl (ord_id, ord_dtl_seq, prd_opt_id, ord_qty, sale_uprc, ship_fee)
WITH g AS (
    SELECT src_ord_no, src_prd_no, sale_uprc,
           COUNT(*)                   AS qty,        -- 반복 행 수 = 주문수량
           COALESCE(SUM(ship_fee), 0) AS fee,
           MIN(src_item_seq)          AS first_seq
    FROM stg.olist_order_items
    GROUP BY src_ord_no, src_prd_no, sale_uprc
)
SELECT o.ord_id,
       ROW_NUMBER() OVER (PARTITION BY g.src_ord_no ORDER BY g.first_seq),
       po.prd_opt_id, g.qty, g.sale_uprc, g.fee
FROM g
JOIN core.ord     o  ON o.src_ord_no = g.src_ord_no
JOIN core.prd     p  ON p.src_prd_no = g.src_prd_no
JOIN core.prd_opt po ON po.prd_id    = p.prd_id;

-- ---------------------------------------------------------------------
-- 8. 결제 (D-014)
-- ---------------------------------------------------------------------
INSERT INTO core.pay (ord_id, pay_seq, pay_mthd_cd, instl_mon_cnt, pay_amt)
SELECT o.ord_id, s.pay_seq, s.pay_mthd_cd, s.instl_mon_cnt, s.pay_amt
FROM stg.olist_order_payments s
JOIN core.ord o ON o.src_ord_no = s.src_ord_no;

-- =====================================================================
-- 이관 대사(reconciliation): stg 기준 건수와 core 적재 건수 비교
-- 모든 행의 match_yn이 Y여야 한다.
-- =====================================================================
SELECT item, stg_cnt, core_cnt, CASE WHEN stg_cnt = core_cnt THEN 'Y' ELSE 'N' END AS match_yn
FROM (
    SELECT '상품' AS item,
           (SELECT COUNT(*) FROM stg.olist_products WHERE lprc IS NOT NULL) AS stg_cnt,
           (SELECT COUNT(*) FROM core.prd) AS core_cnt
    UNION ALL
    SELECT '회원',
           (SELECT COUNT(DISTINCT c.src_mbr_no)
              FROM stg.olist_orders o JOIN stg.olist_customers c ON c.src_cust_no = o.src_cust_no
             WHERE o.trgt_yn = 'Y'),
           (SELECT COUNT(*) FROM core.mbr)
    UNION ALL
    SELECT '주문',
           (SELECT COUNT(*) FROM stg.olist_orders WHERE trgt_yn = 'Y'),
           (SELECT COUNT(*) FROM core.ord)
    UNION ALL
    -- 집계 후에도 수량 합계는 원천 품목 행 수와 같아야 한다
    SELECT '주문 품목 수량',
           (SELECT COUNT(*) FROM stg.olist_order_items),
           (SELECT SUM(ord_qty) FROM core.ord_dtl)
    UNION ALL
    SELECT '주문 판매금액',
           (SELECT SUM(sale_uprc) FROM stg.olist_order_items),
           (SELECT SUM(sale_uprc * ord_qty) FROM core.ord_dtl)
    UNION ALL
    SELECT '결제',
           (SELECT COUNT(*) FROM stg.olist_order_payments),
           (SELECT COUNT(*) FROM core.pay)
) x;
