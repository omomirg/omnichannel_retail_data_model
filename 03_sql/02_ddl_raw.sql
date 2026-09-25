-- =====================================================================
-- raw 계층 DDL (MySQL 8.0)
-- 목적: Olist CSV를 컬럼명·값 모두 원본 그대로 보존
-- 원칙: 모든 컬럼을 문자형(VARCHAR)으로 받는다.
--       타입 변환·NULL 처리·표준명 변경은 staging에서 수행한다.
--       raw에서 변환하면 원본과 대조할 기준이 사라지기 때문이다.
-- 범위: 이관 대상 6개 파일. sellers(D-009), reviews·geolocation(D-010)은 제외
-- =====================================================================

CREATE DATABASE IF NOT EXISTS raw DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
DROP TABLE IF EXISTS raw.olist_customers, raw.olist_orders, raw.olist_order_items,
                     raw.olist_order_payments, raw.olist_products, raw.product_category_name_translation;

-- 테이블명에 raw.를 붙여 USE 문이나 도구의 현재 DB 선택과 무관하게 실행되도록 함
-- 원본 컬럼명을 그대로 사용한다 (오타 product_name_lenght 포함, 원천 품질 이슈 2번)

CREATE TABLE raw.olist_customers (
    customer_id               VARCHAR(255),
    customer_unique_id        VARCHAR(255),
    customer_zip_code_prefix  VARCHAR(255),
    customer_city             VARCHAR(255),
    customer_state            VARCHAR(255)
) COMMENT = 'Olist 원본: olist_customers_dataset.csv';

CREATE TABLE raw.olist_orders (
    order_id                       VARCHAR(255),
    customer_id                    VARCHAR(255),
    order_status                   VARCHAR(255),
    order_purchase_timestamp       VARCHAR(255),
    order_approved_at              VARCHAR(255),
    order_delivered_carrier_date   VARCHAR(255),
    order_delivered_customer_date  VARCHAR(255),
    order_estimated_delivery_date  VARCHAR(255)
) COMMENT = 'Olist 원본: olist_orders_dataset.csv';

CREATE TABLE raw.olist_order_items (
    order_id             VARCHAR(255),
    order_item_id        VARCHAR(255),
    product_id           VARCHAR(255),
    seller_id            VARCHAR(255),
    shipping_limit_date  VARCHAR(255),
    price                VARCHAR(255),
    freight_value        VARCHAR(255)
) COMMENT = 'Olist 원본: olist_order_items_dataset.csv';

CREATE TABLE raw.olist_order_payments (
    order_id              VARCHAR(255),
    payment_sequential    VARCHAR(255),
    payment_type          VARCHAR(255),
    payment_installments  VARCHAR(255),
    payment_value         VARCHAR(255)
) COMMENT = 'Olist 원본: olist_order_payments_dataset.csv';

CREATE TABLE raw.olist_products (
    product_id                  VARCHAR(255),
    product_category_name       VARCHAR(255),
    product_name_lenght         VARCHAR(255),
    product_description_lenght  VARCHAR(255),
    product_photos_qty          VARCHAR(255),
    product_weight_g            VARCHAR(255),
    product_length_cm           VARCHAR(255),
    product_height_cm           VARCHAR(255),
    product_width_cm            VARCHAR(255)
) COMMENT = 'Olist 원본: olist_products_dataset.csv';

CREATE TABLE raw.product_category_name_translation (
    product_category_name          VARCHAR(255),
    product_category_name_english  VARCHAR(255)
) COMMENT = 'Olist 원본: product_category_name_translation.csv';
