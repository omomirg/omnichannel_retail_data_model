-- =====================================================================
-- raw 적재 (MySQL 8.0)
-- 사전 준비
--   1) 서버에서 로컬 파일 적재 허용:  SET GLOBAL local_infile = 1;
--   2) DBeaver 연결 설정 → 드라이버 속성 → allowLoadLocalInfile = true
--   3) 아래 경로의 /Users/kimgarim/Desktop/olist/ 부분을 CSV가 있는 실제 폴더로 바꾸기
-- =====================================================================

-- 재실행 시 중복 적재를 막기 위해 먼저 비운다
TRUNCATE TABLE raw.olist_customers;
TRUNCATE TABLE raw.olist_orders;
TRUNCATE TABLE raw.olist_order_items;
TRUNCATE TABLE raw.olist_order_payments;
TRUNCATE TABLE raw.olist_products;
TRUNCATE TABLE raw.product_category_name_translation;

-- 공통 옵션 설명
--   FIELDS TERMINATED BY ','        : 쉼표로 컬럼 구분
--   OPTIONALLY ENCLOSED BY '"'      : 큰따옴표로 감싼 값은 따옴표를 벗겨서 저장
--   LINES TERMINATED BY '\n'        : 줄바꿈으로 행 구분
--   IGNORE 1 LINES                  : 첫 줄(헤더)은 건너뜀
--   빈 값은 NULL이 아니라 빈 문자열('')로 들어간다. NULL 변환은 staging에서 한다.

LOAD DATA LOCAL INFILE '/Users/kimgarim/Desktop/olist/olist_customers_dataset.csv'
INTO TABLE raw.olist_customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/Users/kimgarim/Desktop/olist/olist_orders_dataset.csv'
INTO TABLE raw.olist_orders
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/Users/kimgarim/Desktop/olist/olist_order_items_dataset.csv'
INTO TABLE raw.olist_order_items
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/Users/kimgarim/Desktop/olist/olist_order_payments_dataset.csv'
INTO TABLE raw.olist_order_payments
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/Users/kimgarim/Desktop/olist/olist_products_dataset.csv'
INTO TABLE raw.olist_products
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/Users/kimgarim/Desktop/olist/product_category_name_translation.csv'
INTO TABLE raw.product_category_name_translation
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'   -- 이 파일만 윈도우 형식 줄바꿈 (원천 품질 이슈 7번)
IGNORE 1 LINES;

-- =====================================================================
-- 적재 검증 1: 행 수가 원천 탐색(01_olist.ipynb) 결과와 같은가
-- =====================================================================
SELECT 'olist_customers' AS tbl, COUNT(*) AS loaded, 99441 AS expected FROM raw.olist_customers
UNION ALL SELECT 'olist_orders',         COUNT(*),  99441 FROM raw.olist_orders
UNION ALL SELECT 'olist_order_items',    COUNT(*), 112650 FROM raw.olist_order_items
UNION ALL SELECT 'olist_order_payments', COUNT(*), 103886 FROM raw.olist_order_payments
UNION ALL SELECT 'olist_products',       COUNT(*),  32951 FROM raw.olist_products
UNION ALL SELECT 'category_translation', COUNT(*),     71 FROM raw.product_category_name_translation;

-- =====================================================================
-- 적재 검증 2: 줄 끝 문자(\r) 확인
-- 윈도우 형식 줄바꿈(\r\n) 파일이면 마지막 컬럼 끝에 \r이 붙는다.
-- 0이 아니면 해당 테이블만 LINES TERMINATED BY '\r\n'으로 바꿔 다시 적재한다.
-- =====================================================================
SELECT 'olist_customers' AS tbl, SUM(customer_state LIKE '%\r') AS cr_rows FROM raw.olist_customers
UNION ALL SELECT 'olist_orders',         SUM(order_estimated_delivery_date LIKE '%\r') FROM raw.olist_orders
UNION ALL SELECT 'olist_order_items',    SUM(freight_value LIKE '%\r') FROM raw.olist_order_items
UNION ALL SELECT 'olist_order_payments', SUM(payment_value LIKE '%\r') FROM raw.olist_order_payments
UNION ALL SELECT 'olist_products',       SUM(product_width_cm LIKE '%\r') FROM raw.olist_products
UNION ALL SELECT 'category_translation', SUM(product_category_name_english LIKE '%\r') FROM raw.product_category_name_translation;
