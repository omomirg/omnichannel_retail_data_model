-- =====================================================================
-- raw → stg 변환 (MySQL 8.0)
-- 기준: mapping_spec.xlsx (적용 계층 = stg 인 규칙)
-- stg의 역할: 원천 1행 = stg 1행 구조를 유지하면서
--   1) 표준 물리명으로 변경 (표준 사전)   2) 타입 변환
--   3) 빈 문자열 → NULL                   4) 코드값 표준화 (코드매핑 시트)
--   5) 이관 대상 표시·필터링 (D-012)
-- 재실행 가능: stg 테이블을 지우고 다시 만든다.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS stg DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

DROP TABLE IF EXISTS stg.olist_customers, stg.olist_orders, stg.olist_products,
                     stg.olist_order_items, stg.olist_order_payments;

-- ---------------------------------------------------------------------
-- 1. 고객: 원천 전체 (주문 → 회원 연결과 회원 주소 산출에 사용)
-- ---------------------------------------------------------------------
CREATE TABLE stg.olist_customers (
    src_cust_no  VARCHAR(32)  NOT NULL COMMENT '원천고객번호 (customer_id, 주문마다 발급)',
    src_mbr_no   VARCHAR(32)  NOT NULL COMMENT '원천회원번호 (customer_unique_id)',
    zip_no       VARCHAR(10)  NULL     COMMENT '우편번호',
    city_nm      VARCHAR(100) NULL     COMMENT '도시명',
    st_nm        VARCHAR(100) NULL     COMMENT '주명',
    PRIMARY KEY (src_cust_no),
    KEY ix_stg_cust_mbr (src_mbr_no)
) COMMENT = 'stg 고객';

INSERT INTO stg.olist_customers
SELECT TRIM(customer_id),
       TRIM(customer_unique_id),
       LPAD(NULLIF(TRIM(customer_zip_code_prefix), ''), 5, '0'),   -- 앞자리 0 보존
       NULLIF(TRIM(customer_city), ''),                            -- 빈 문자열 → NULL
       NULLIF(TRIM(customer_state), '')
FROM raw.olist_customers;

-- ---------------------------------------------------------------------
-- 2. 주문: 원천 전체를 적재하고 이관 대상 여부를 trgt_yn으로 표시
--    전체를 두는 이유: 회원 가입일시 = 그 사람의 원천 전체 주문 중 최초 일시 (D-023)
--    이관 대상: 모든 품목이 beleza_saude 상품인 주문 (D-012)
-- ---------------------------------------------------------------------
CREATE TABLE stg.olist_orders (
    src_ord_no     VARCHAR(32) NOT NULL COMMENT '원천주문번호',
    src_cust_no    VARCHAR(32) NOT NULL COMMENT '원천고객번호',
    ord_stat_cd    VARCHAR(20) NOT NULL COMMENT '주문상태코드 (표준 코드)',
    ord_dtm        DATETIME    NOT NULL COMMENT '주문일시',
    pay_aprv_dtm   DATETIME    NULL     COMMENT '결제승인일시',
    prcl_hndv_dtm  DATETIME    NULL     COMMENT '택배인계일시',
    rcv_cmpl_dtm   DATETIME    NULL     COMMENT '수령완료일시',
    est_rcv_dt     DATE        NULL     COMMENT '예상수령일자',
    trgt_yn        CHAR(1)     NOT NULL COMMENT '이관대상여부 (D-012)',
    PRIMARY KEY (src_ord_no),
    KEY ix_stg_ord_cust (src_cust_no)
) COMMENT = 'stg 주문';

INSERT INTO stg.olist_orders
SELECT TRIM(o.order_id),
       TRIM(o.customer_id),
       -- 코드매핑 시트 적용. 매핑되지 않은 값은 원천 값 그대로 두어 품질 점검에서 검출
       CASE TRIM(o.order_status)
            WHEN 'created'     THEN 'ORDERED'
            WHEN 'approved'    THEN 'PAID'
            WHEN 'invoiced'    THEN 'PAID'
            WHEN 'processing'  THEN 'PAID'
            WHEN 'shipped'     THEN 'SHIPPED'
            WHEN 'delivered'   THEN 'RECEIVED'
            WHEN 'canceled'    THEN 'CANCELED'
            WHEN 'unavailable' THEN 'CANCELED'
            ELSE TRIM(o.order_status)
       END,
       -- 원천 형식을 명시해 문자 → 일시 변환 (형식이 다르면 NULL이 되어 품질 점검에서 드러남)
       STR_TO_DATE(NULLIF(TRIM(o.order_purchase_timestamp), ''),      '%Y-%m-%d %H:%i:%s'),
       STR_TO_DATE(NULLIF(TRIM(o.order_approved_at), ''),             '%Y-%m-%d %H:%i:%s'),
       STR_TO_DATE(NULLIF(TRIM(o.order_delivered_carrier_date), ''),  '%Y-%m-%d %H:%i:%s'),
       STR_TO_DATE(NULLIF(TRIM(o.order_delivered_customer_date), ''), '%Y-%m-%d %H:%i:%s'),
       DATE(STR_TO_DATE(NULLIF(TRIM(o.order_estimated_delivery_date), ''), '%Y-%m-%d %H:%i:%s')),
       CASE WHEN t.order_id IS NULL THEN 'N' ELSE 'Y' END
FROM raw.olist_orders o
LEFT JOIN (
    -- 품목 전체가 beleza_saude인 주문만 대상. 카테고리가 없거나 다른 품목이 하나라도 있으면 제외
    SELECT TRIM(i.order_id) AS order_id
    FROM raw.olist_order_items i
    LEFT JOIN raw.olist_products p ON p.product_id = i.product_id
    GROUP BY TRIM(i.order_id)
    HAVING SUM(COALESCE(TRIM(p.product_category_name) = 'beleza_saude', 0)) = COUNT(*)
) t ON t.order_id = TRIM(o.order_id);

-- ---------------------------------------------------------------------
-- 3. 상품: beleza_saude 상품만. 정가 = 원천 전체 주문 품목 중 최고 판매가 (D-015)
-- ---------------------------------------------------------------------
CREATE TABLE stg.olist_products (
    src_prd_no   VARCHAR(32)   NOT NULL COMMENT '원천상품번호',
    src_ctgr_cd  VARCHAR(20)   NOT NULL COMMENT '원천카테고리코드',
    wt           INTEGER       NULL     COMMENT '중량 (g)',
    len          INTEGER       NULL     COMMENT '길이 (cm)',
    hgt          INTEGER       NULL     COMMENT '높이 (cm)',
    wdt          INTEGER       NULL     COMMENT '너비 (cm)',
    lprc         DECIMAL(12,2) NULL     COMMENT '정가 (판매 이력 없으면 NULL)',
    PRIMARY KEY (src_prd_no)
) COMMENT = 'stg 상품';

INSERT INTO stg.olist_products
SELECT TRIM(p.product_id),
       TRIM(p.product_category_name),
       -- 문자 → 소수 → 반올림 정수 ('225'와 '225.0' 모두 처리)
       CAST(ROUND(CAST(NULLIF(TRIM(p.product_weight_g), '')  AS DECIMAL(12,2))) AS SIGNED),
       CAST(ROUND(CAST(NULLIF(TRIM(p.product_length_cm), '') AS DECIMAL(12,2))) AS SIGNED),
       CAST(ROUND(CAST(NULLIF(TRIM(p.product_height_cm), '') AS DECIMAL(12,2))) AS SIGNED),
       CAST(ROUND(CAST(NULLIF(TRIM(p.product_width_cm), '')  AS DECIMAL(12,2))) AS SIGNED),
       mp.max_price
FROM raw.olist_products p
LEFT JOIN (
    SELECT TRIM(product_id) AS product_id,
           MAX(CAST(NULLIF(TRIM(price), '') AS DECIMAL(12,2))) AS max_price
    FROM raw.olist_order_items
    GROUP BY TRIM(product_id)
) mp ON mp.product_id = TRIM(p.product_id)
WHERE TRIM(p.product_category_name) = 'beleza_saude';

-- ---------------------------------------------------------------------
-- 4. 주문 품목: 이관 대상 주문만. 원천처럼 상품 1개 = 1행 유지 (수량 집계는 core에서)
-- ---------------------------------------------------------------------
CREATE TABLE stg.olist_order_items (
    src_ord_no    VARCHAR(32)   NOT NULL COMMENT '원천주문번호',
    src_item_seq  INTEGER       NOT NULL COMMENT '원천품목순번 (order_item_id)',
    src_prd_no    VARCHAR(32)   NOT NULL COMMENT '원천상품번호',
    sale_uprc     DECIMAL(12,2) NOT NULL COMMENT '판매단가',
    ship_fee      DECIMAL(12,2) NULL     COMMENT '배송비',
    PRIMARY KEY (src_ord_no, src_item_seq)
) COMMENT = 'stg 주문 품목';

INSERT INTO stg.olist_order_items
SELECT TRIM(i.order_id),
       CAST(TRIM(i.order_item_id) AS UNSIGNED),
       TRIM(i.product_id),
       CAST(NULLIF(TRIM(i.price), '')         AS DECIMAL(12,2)),
       CAST(NULLIF(TRIM(i.freight_value), '') AS DECIMAL(12,2))
FROM raw.olist_order_items i
JOIN stg.olist_orders o ON o.src_ord_no = TRIM(i.order_id) AND o.trgt_yn = 'Y';

-- ---------------------------------------------------------------------
-- 5. 결제: 이관 대상 주문만
-- ---------------------------------------------------------------------
CREATE TABLE stg.olist_order_payments (
    src_ord_no     VARCHAR(32)   NOT NULL COMMENT '원천주문번호',
    pay_seq        INTEGER       NOT NULL COMMENT '결제순번',
    pay_mthd_cd    VARCHAR(20)   NOT NULL COMMENT '결제수단코드 (표준 코드)',
    instl_mon_cnt  INTEGER       NOT NULL COMMENT '할부개월수',
    pay_amt        DECIMAL(12,2) NOT NULL COMMENT '결제금액',
    PRIMARY KEY (src_ord_no, pay_seq)
) COMMENT = 'stg 결제';

INSERT INTO stg.olist_order_payments
SELECT TRIM(p.order_id),
       CAST(TRIM(p.payment_sequential) AS UNSIGNED),
       CASE TRIM(p.payment_type)
            WHEN 'credit_card' THEN 'CREDIT'
            WHEN 'debit_card'  THEN 'DEBIT'
            WHEN 'boleto'      THEN 'BANK_SLIP'
            WHEN 'voucher'     THEN 'VOUCHER'
            ELSE TRIM(p.payment_type)          -- not_defined 등은 그대로 두어 품질 점검에서 검출
       END,
       CAST(TRIM(p.payment_installments) AS UNSIGNED),
       CAST(NULLIF(TRIM(p.payment_value), '') AS DECIMAL(12,2))
FROM raw.olist_order_payments p
JOIN stg.olist_orders o ON o.src_ord_no = TRIM(p.order_id) AND o.trgt_yn = 'Y';

-- =====================================================================
-- stg 점검 (결과 탭 3개)
-- =====================================================================
-- (1) 건수: 이관 대상 주문은 원천 탐색 결과 8,764건이어야 함 (8,836 - 혼합 72)
SELECT 'orders 전체'       AS item, COUNT(*) AS cnt FROM stg.olist_orders
UNION ALL SELECT 'orders 이관대상', COUNT(*) FROM stg.olist_orders WHERE trgt_yn = 'Y'
UNION ALL SELECT 'products',        COUNT(*) FROM stg.olist_products
UNION ALL SELECT 'order_items',     COUNT(*) FROM stg.olist_order_items
UNION ALL SELECT 'order_payments',  COUNT(*) FROM stg.olist_order_payments;

-- (2) D-013 남은 확인: 같은 주문·같은 상품인데 단가가 다른 경우의 수
SELECT COUNT(*) AS diff_price_groups
FROM (SELECT src_ord_no, src_prd_no
      FROM stg.olist_order_items
      GROUP BY src_ord_no, src_prd_no
      HAVING COUNT(DISTINCT sale_uprc) > 1) x;

-- (3) 판매 이력이 없어 정가를 정할 수 없는 상품 (core 이관에서 제외됨, 0 예상)
SELECT COUNT(*) AS no_price_products FROM stg.olist_products WHERE lprc IS NULL;
