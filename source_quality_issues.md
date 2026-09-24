# 원천 데이터 품질 이슈 목록

Olist 원천 데이터 탐색(`01_olist.ipynb`) 과정에서 발견한 품질 이슈를 기록한다.
처리 방침은 `decision_log.md`의 D-020을 따른다.

| No | 테이블 | 이슈 | 규모 | 처리 |
|---|---|---|---|---|
| 1 | products | 카테고리 값 NULL | 610건 | health_beauty 필터 대상이 아니므로 이관 범위 밖 |
| 2 | products | 컬럼명 오타 (product_name_lenght, product_description_lenght) | 2개 컬럼 | raw는 원본 유지, staging에서 표준 용어로 변경 |
| 3 | order_items, order_payments | 품목 합계(가격+운임)와 결제 합계 불일치 (0.01 이상) | 17 / 8,835건 | 이관 후 품질 점검에서 검출·보고 |
| 4 | order_payments | 결제 기록이 없는 주문 | 1건 | 이관 후 품질 점검에서 검출·보고 |
| 5 | customers | customer_id가 주문마다 새로 발급되어 동일인이 여러 ID를 가짐 | 2,997명 | customer_unique_id 기준으로 회원 통합 (D-011) |
| 6 | order_items | 수량 컬럼 없이 상품 1개당 1행으로 저장 | 461 / 9,022건 반복 | 주문수량으로 집계 (D-013) |

※ 3, 4번 건수는 health_beauty 포함 주문 기준이다. D-012에 따라 혼합 주문 72건 제외 후 다시 집계한다.
