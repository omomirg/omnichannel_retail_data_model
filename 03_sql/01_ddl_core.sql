-- =====================================================================
-- core 계층 DDL (MySQL 8.0)
-- 기준: 물리 ERD, 표준 사전(data_standard_dictionary.xlsx), decision_log.md
-- 규칙: 사전·ERD는 대문자 표기, DB에는 소문자로 생성 (D-025)
--       컬럼 COMMENT에 한글 논리명을 기록해 약어의 가독성을 보완
-- =====================================================================

CREATE DATABASE IF NOT EXISTS core DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE core;

-- 재실행할 수 있도록 기존 테이블 삭제 (FK 검사를 잠시 끄고 순서 무관하게 삭제)
SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS stck_chg_hist, str_stck, pay, ord_dtl, ord, prd_opt, prd, str, mbr, brnd, ctgr;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 기준 정보 (마스터)
-- ---------------------------------------------------------------------

CREATE TABLE ctgr (
    ctgr_id       BIGINT       NOT NULL AUTO_INCREMENT COMMENT '카테고리ID',
    uppr_ctgr_id  BIGINT       NULL                    COMMENT '상위카테고리ID (대분류는 NULL)',
    ctgr_nm       VARCHAR(100) NOT NULL                COMMENT '카테고리명',
    ctgr_lvl      SMALLINT     NOT NULL                COMMENT '카테고리레벨 (1 대분류, 2 중분류)',
    src_ctgr_cd   VARCHAR(20)  NULL                    COMMENT '원천카테고리코드',
    PRIMARY KEY (ctgr_id),
    -- 자기참조: 상위 카테고리도 같은 테이블의 행 (D-024)
    CONSTRAINT fk_ctgr_uppr FOREIGN KEY (uppr_ctgr_id) REFERENCES ctgr (ctgr_id),
    CONSTRAINT ck_ctgr_lvl  CHECK (ctgr_lvl IN (1, 2))
) ENGINE = InnoDB COMMENT = '카테고리';

CREATE TABLE brnd (
    brnd_id  BIGINT       NOT NULL AUTO_INCREMENT COMMENT '브랜드ID',
    brnd_nm  VARCHAR(100) NOT NULL                COMMENT '브랜드명',
    PRIMARY KEY (brnd_id)
) ENGINE = InnoDB COMMENT = '브랜드';

CREATE TABLE mbr (
    mbr_id        BIGINT       NOT NULL AUTO_INCREMENT COMMENT '회원ID (대체키, D-011)',
    src_mbr_no    VARCHAR(32)  NULL                    COMMENT '원천회원번호 (customer_unique_id)',
    join_chnl_cd  VARCHAR(20)  NOT NULL                COMMENT '가입채널코드',
    join_dtm      DATETIME     NOT NULL                COMMENT '가입일시 (Olist는 첫 주문일시, D-023)',
    zip_no        VARCHAR(10)  NULL                    COMMENT '우편번호',
    city_nm       VARCHAR(100) NULL                    COMMENT '도시명',
    st_nm         VARCHAR(100) NULL                    COMMENT '주명',
    PRIMARY KEY (mbr_id),
    -- 원천 식별자 중복 방지. NULL(가상 매장 회원)은 여러 건 허용됨
    UNIQUE KEY uk_mbr_src (src_mbr_no)
) ENGINE = InnoDB COMMENT = '회원';

CREATE TABLE str (
    str_id   BIGINT       NOT NULL AUTO_INCREMENT COMMENT '매장ID',
    str_nm   VARCHAR(100) NOT NULL                COMMENT '매장명',
    zip_no   VARCHAR(10)  NOT NULL                COMMENT '우편번호',
    city_nm  VARCHAR(100) NOT NULL                COMMENT '도시명',
    st_nm    VARCHAR(100) NOT NULL                COMMENT '주명',
    open_dt  DATE         NOT NULL                COMMENT '개점일자',
    PRIMARY KEY (str_id)
) ENGINE = InnoDB COMMENT = '매장';

CREATE TABLE prd (
    prd_id      BIGINT        NOT NULL AUTO_INCREMENT COMMENT '상품ID',
    ctgr_id     BIGINT        NOT NULL                COMMENT '카테고리ID',
    brnd_id     BIGINT        NOT NULL                COMMENT '브랜드ID',
    src_prd_no  VARCHAR(32)   NULL                    COMMENT '원천상품번호 (product_id)',
    prd_nm      VARCHAR(100)  NOT NULL                COMMENT '상품명',
    lprc        DECIMAL(12,2) NOT NULL                COMMENT '정가 (D-015)',
    wt          INTEGER       NULL                    COMMENT '중량 (g)',
    len         INTEGER       NULL                    COMMENT '길이 (cm)',
    hgt         INTEGER       NULL                    COMMENT '높이 (cm)',
    wdt         INTEGER       NULL                    COMMENT '너비 (cm)',
    PRIMARY KEY (prd_id),
    UNIQUE KEY uk_prd_src (src_prd_no),
    CONSTRAINT fk_prd_ctgr FOREIGN KEY (ctgr_id) REFERENCES ctgr (ctgr_id),
    CONSTRAINT fk_prd_brnd FOREIGN KEY (brnd_id) REFERENCES brnd (brnd_id)
) ENGINE = InnoDB COMMENT = '상품';

CREATE TABLE prd_opt (
    prd_opt_id  BIGINT       NOT NULL AUTO_INCREMENT COMMENT '상품옵션ID (SKU)',
    prd_id      BIGINT       NOT NULL                COMMENT '상품ID',
    opt_nm      VARCHAR(100) NOT NULL                COMMENT '옵션명',
    PRIMARY KEY (prd_opt_id),
    CONSTRAINT fk_prd_opt_prd FOREIGN KEY (prd_id) REFERENCES prd (prd_id)
) ENGINE = InnoDB COMMENT = '상품옵션';

-- ---------------------------------------------------------------------
-- 주문 영역
-- ---------------------------------------------------------------------

CREATE TABLE ord (
    ord_id          BIGINT       NOT NULL AUTO_INCREMENT COMMENT '주문ID',
    mbr_id          BIGINT       NULL                    COMMENT '회원ID (매장 비회원은 NULL, D-018)',
    str_id          BIGINT       NULL                    COMMENT '매장ID (출고매장, 택배배송은 NULL, D-017)',
    src_ord_no      VARCHAR(32)  NULL                    COMMENT '원천주문번호 (order_id)',
    sale_chnl_cd    VARCHAR(20)  NOT NULL                COMMENT '판매채널코드',
    ord_stat_cd     VARCHAR(20)  NOT NULL                COMMENT '주문상태코드',
    ord_dtm         DATETIME     NOT NULL                COMMENT '주문일시',
    pay_aprv_dtm    DATETIME     NULL                    COMMENT '결제승인일시',
    pack_cmpl_dtm   DATETIME     NULL                    COMMENT '포장완료일시 (D-005)',
    prcl_hndv_dtm   DATETIME     NULL                    COMMENT '택배인계일시',
    rcv_cmpl_dtm    DATETIME     NULL                    COMMENT '수령완료일시 (D-022)',
    est_rcv_dt      DATE         NULL                    COMMENT '예상수령일자',
    cncl_dtm        DATETIME     NULL                    COMMENT '취소일시',
    shpto_zip_no    VARCHAR(10)  NULL                    COMMENT '배송지우편번호',
    shpto_city_nm   VARCHAR(100) NULL                    COMMENT '배송지도시명',
    shpto_st_nm     VARCHAR(100) NULL                    COMMENT '배송지주명',
    PRIMARY KEY (ord_id),
    UNIQUE KEY uk_ord_src (src_ord_no),
    -- 채널별 매출·일자별 조회가 잦아 조회용 인덱스 추가
    KEY ix_ord_dtm (ord_dtm),
    CONSTRAINT fk_ord_mbr FOREIGN KEY (mbr_id) REFERENCES mbr (mbr_id),
    CONSTRAINT fk_ord_str FOREIGN KEY (str_id) REFERENCES str (str_id)
) ENGINE = InnoDB COMMENT = '주문';

CREATE TABLE ord_dtl (
    ord_id       BIGINT        NOT NULL COMMENT '주문ID',
    ord_dtl_seq  INTEGER       NOT NULL COMMENT '주문상세순번',
    prd_opt_id   BIGINT        NOT NULL COMMENT '상품옵션ID',
    ord_qty      INTEGER       NOT NULL COMMENT '주문수량 (D-013)',
    sale_uprc    DECIMAL(12,2) NOT NULL COMMENT '판매단가 (주문 시점 가격, D-019)',
    ship_fee     DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT '배송비 (매장판매는 0)',
    -- 식별 관계: 부모(주문)의 키 + 순번이 PK
    PRIMARY KEY (ord_id, ord_dtl_seq),
    CONSTRAINT fk_ord_dtl_ord     FOREIGN KEY (ord_id)     REFERENCES ord (ord_id),
    CONSTRAINT fk_ord_dtl_prd_opt FOREIGN KEY (prd_opt_id) REFERENCES prd_opt (prd_opt_id),
    CONSTRAINT ck_ord_dtl_qty     CHECK (ord_qty > 0)
) ENGINE = InnoDB COMMENT = '주문상세';

CREATE TABLE pay (
    ord_id         BIGINT        NOT NULL COMMENT '주문ID',
    pay_seq        INTEGER       NOT NULL COMMENT '결제순번 (D-014)',
    pay_mthd_cd    VARCHAR(20)   NOT NULL COMMENT '결제수단코드',
    instl_mon_cnt  INTEGER       NOT NULL DEFAULT 0 COMMENT '할부개월수',
    pay_amt        DECIMAL(12,2) NOT NULL COMMENT '결제금액',
    PRIMARY KEY (ord_id, pay_seq),
    CONSTRAINT fk_pay_ord FOREIGN KEY (ord_id) REFERENCES ord (ord_id)
) ENGINE = InnoDB COMMENT = '결제';

-- ---------------------------------------------------------------------
-- 재고 영역
-- ---------------------------------------------------------------------

CREATE TABLE str_stck (
    str_id        BIGINT      NOT NULL COMMENT '매장ID',
    prd_opt_id    BIGINT      NOT NULL COMMENT '상품옵션ID',
    stck_stat_cd  VARCHAR(20) NOT NULL COMMENT '재고상태코드 (AVAIL, ORD_HOLD, TESTER)',
    stck_qty      INTEGER     NOT NULL COMMENT '재고수량',
    last_chg_dtm  DATETIME    NOT NULL COMMENT '최종변동일시',
    -- 행 방식: 매장·SKU·재고상태별로 한 행 (D-002)
    PRIMARY KEY (str_id, prd_opt_id, stck_stat_cd),
    CONSTRAINT fk_str_stck_str     FOREIGN KEY (str_id)     REFERENCES str (str_id),
    CONSTRAINT fk_str_stck_prd_opt FOREIGN KEY (prd_opt_id) REFERENCES prd_opt (prd_opt_id)
) ENGINE = InnoDB COMMENT = '매장재고';

CREATE TABLE stck_chg_hist (
    stck_chg_id   BIGINT      NOT NULL AUTO_INCREMENT COMMENT '재고변동ID',
    str_id        BIGINT      NOT NULL COMMENT '매장ID',
    prd_opt_id    BIGINT      NOT NULL COMMENT '상품옵션ID',
    ord_id        BIGINT      NULL     COMMENT '주문ID (원인 주문, 입고·실사조정은 NULL, D-021)',
    stck_stat_cd  VARCHAR(20) NOT NULL COMMENT '재고상태코드',
    chg_type_cd   VARCHAR(20) NOT NULL COMMENT '변동유형코드',
    chg_qty       INTEGER     NOT NULL COMMENT '변동수량 (증가 +, 감소 -)',
    chg_dtm       DATETIME    NOT NULL COMMENT '변동일시',
    adj_rsn_cd    VARCHAR(20) NULL     COMMENT '조정사유코드 (실사조정일 때만, D-007)',
    PRIMARY KEY (stck_chg_id),
    -- 재고 합계 점검(매장재고 = 변동이력 누적)에서 이 순서로 묶어 집계함
    KEY ix_stck_chg_hist_key (str_id, prd_opt_id, stck_stat_cd, chg_dtm),
    CONSTRAINT fk_stck_chg_hist_str     FOREIGN KEY (str_id)     REFERENCES str (str_id),
    CONSTRAINT fk_stck_chg_hist_prd_opt FOREIGN KEY (prd_opt_id) REFERENCES prd_opt (prd_opt_id),
    CONSTRAINT fk_stck_chg_hist_ord     FOREIGN KEY (ord_id)     REFERENCES ord (ord_id),
    CONSTRAINT ck_stck_chg_hist_qty     CHECK (chg_qty <> 0)
) ENGINE = InnoDB COMMENT = '재고변동이력';
