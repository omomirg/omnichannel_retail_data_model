"""
가상 데이터 생성: 매장 · 매장 가입 회원 · 매장 채널 주문 · 매장재고 · 재고변동이력
-----------------------------------------------------------------------------
실행 전제: 01_ddl_core.sql → 04_transform_stg.sql → 05_transform_core.sql 실행 완료
실행 방법: pip install pymysql  →  python generate_store_data.py
재실행 가능: 이전에 만든 가상 데이터만 지우고 다시 만든다 (Olist 이관 데이터는 유지).

설계 원칙
- 재현성: 난수 시드를 고정해 몇 번을 실행해도 같은 데이터가 나온다.
- 일관성: 모든 재고 변화를 시간 순서대로 시뮬레이션하고, 매장재고는 변동이력의 누적 결과로 만든다.
  → 판매 가능 재고가 음수가 되는 주문은 만들지 않는다.
- 현실성: 매장 위치는 원천 회원이 가장 많은 도시로 정한다 (Olist 고객 분포 활용).
- 설계 결정 반영: 포장완료 후 취소(D-006), 실사조정 사유와 복원 패턴(D-007, D-008),
  재고상태 가용·주문보관·테스터(D-002, D-003), 매장 비회원 결제(D-018)
- 의도적 불일치: 매장재고 5행은 변동이력 없이 수량을 1 줄여, 품질 점검에서 검출되는지 확인한다.
"""
import os
import heapq
import random
import getpass
from datetime import datetime, timedelta, date
from decimal import Decimal, ROUND_HALF_UP

import pymysql

# ---------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------
SEED = 20260925
START = datetime(2017, 1, 1)                  # 원천 주문이 충분히 쌓인 시점부터
END = datetime(2018, 8, 29, 23, 59, 59)       # 원천 마지막 주문일 (D-016)
N_STORES = 4
SKUS_PER_STORE = 200
N_STORE_MEMBERS = 800                         # 매장에서 가입한 회원
OPEN_H, CLOSE_H = 10, 22                      # 영업시간

STORE_SALE_PER_DAY = 4.0                      # 매장별 하루 평균 매장판매 주문 수
PICKUP_PER_DAY = 1.0                          # 매장픽업
SHIP_PER_DAY = 0.5                            # 매장출고배송
MEMBER_RATE_STORE = 0.4                       # 매장판매 중 회원 비율 (나머지는 비회원, D-018)
CANCEL_BEFORE_PACK = 0.05                     # 포장 전 취소 비율
CANCEL_AFTER_PACK = 0.10                      # 포장완료 후 취소 비율 (평상시)
CANCEL_AFTER_PACK_SALE = 0.25                 # 포장완료 후 취소 비율 (할인 행사 기간)

# 할인 행사 기간: 온라인 주문 3배, 취소율 상승, 판매가 20% 할인
SALE_PERIODS = [(date(2017, 11, 20), date(2017, 11, 26)),
                (date(2018, 5, 21), date(2018, 5, 27))]

rng = random.Random(SEED)


def q2(x):
    """금액을 소수 둘째 자리로 반올림"""
    return Decimal(x).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def poisson(lam):
    """하루 주문 건수용 포아송 난수 (numpy 없이)"""
    L, k, p = pow(2.718281828, -lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= L:
            return k
        k += 1


def in_sale(d):
    return any(s <= d <= e for s, e in SALE_PERIODS)


def rand_time_on(d):
    """영업시간 안의 임의 시각"""
    return datetime(d.year, d.month, d.day, OPEN_H) + timedelta(
        seconds=rng.randint(0, (CLOSE_H - OPEN_H) * 3600 - 1))


def next_open(t):
    """영업시간 밖이면 다음 영업 시작 시각 이후로 미룸"""
    if t.hour < OPEN_H:
        t = t.replace(hour=OPEN_H, minute=0, second=0) + timedelta(minutes=rng.randint(5, 60))
    elif t.hour >= CLOSE_H:
        t = (t + timedelta(days=1)).replace(hour=OPEN_H, minute=0, second=0) + timedelta(minutes=rng.randint(5, 60))
    return t


# ---------------------------------------------------------------------
# DB 연결
# ---------------------------------------------------------------------
pwd = os.environ["MYSQL_PASSWORD"] if "MYSQL_PASSWORD" in os.environ else getpass.getpass("MySQL root 비밀번호: ")
conn = pymysql.connect(host="localhost", user="root", password=pwd, database="core",
                       charset="utf8mb4", autocommit=False)
cur = conn.cursor()

# ---------------------------------------------------------------------
# 0. 이전 가상 데이터 삭제 (Olist 이관분은 유지)
# ---------------------------------------------------------------------
cur.execute("DELETE FROM stck_chg_hist")
cur.execute("DELETE FROM str_stck")
cur.execute("DELETE p FROM pay p JOIN ord o ON o.ord_id = p.ord_id WHERE o.sale_chnl_cd <> 'PARCEL'")
cur.execute("DELETE d FROM ord_dtl d JOIN ord o ON o.ord_id = d.ord_id WHERE o.sale_chnl_cd <> 'PARCEL'")
cur.execute("DELETE FROM ord WHERE sale_chnl_cd <> 'PARCEL'")
cur.execute("DELETE FROM mbr WHERE join_chnl_cd = 'STORE'")
cur.execute("DELETE FROM str")
conn.commit()

# ---------------------------------------------------------------------
# 1. 기준 정보 읽기
# ---------------------------------------------------------------------
# 매장 위치: 원천 회원이 가장 많은 도시 상위 N개
cur.execute("""
    SELECT city_nm, st_nm, MIN(zip_no), COUNT(*) AS cnt
    FROM mbr WHERE city_nm IS NOT NULL AND st_nm IS NOT NULL AND zip_no IS NOT NULL
    GROUP BY city_nm, st_nm ORDER BY cnt DESC LIMIT %s""", (N_STORES,))
cities = cur.fetchall()

cur.execute("SELECT po.prd_opt_id, p.lprc FROM prd_opt po JOIN prd p ON p.prd_id = po.prd_id ORDER BY po.prd_opt_id")
all_skus = [(r[0], Decimal(r[1])) for r in cur.fetchall()]
price = dict(all_skus)

cur.execute("SELECT mbr_id, city_nm, st_nm, zip_no FROM mbr ORDER BY mbr_id")
online_mbrs = cur.fetchall()

cur.execute("SELECT COALESCE(MAX(ord_id), 0), (SELECT COALESCE(MAX(mbr_id), 0) FROM mbr) FROM ord")
max_ord, max_mbr = cur.fetchone()

# ---------------------------------------------------------------------
# 2. 매장, 매장 가입 회원
# ---------------------------------------------------------------------
stores = []
for i, (city, st, zipno, _) in enumerate(cities, start=1):
    stores.append(dict(str_id=i, str_nm=f"{city.title()}점", zip_no=zipno, city_nm=city,
                       st_nm=st, open_dt=date(2016, 12, 1) + timedelta(days=5 * i)))

store_mbrs = []                       # (mbr_id, join_dtm, str_id)
for k in range(N_STORE_MEMBERS):
    s = rng.choice(stores)
    jd = START + timedelta(seconds=rng.randint(0, int((END - START).total_seconds() * 0.9)))
    store_mbrs.append((max_mbr + 1 + k, jd, s["str_id"]))
store_mbrs.sort(key=lambda x: x[1])

# 온라인 채널(픽업·매장출고) 주문자는 매장과 같은 도시 회원 우선
local_mbrs = {s["str_id"]: [m for m in online_mbrs if m[1] == s["city_nm"]] or online_mbrs for s in stores}

# 매장별 취급 SKU
store_skus = {s["str_id"]: rng.sample([x[0] for x in all_skus], min(SKUS_PER_STORE, len(all_skus))) for s in stores}

# ---------------------------------------------------------------------
# 3. 시간 순 시뮬레이션
#    이벤트를 (시각, 순번, 종류, 내용) 형태로 우선순위 큐에 넣고 시각 순서대로 처리한다.
# ---------------------------------------------------------------------
stock = {}          # (str_id, prd_opt_id, 재고상태) → 수량
last_chg = {}       # 같은 키의 최종변동일시
hist = []           # 재고변동이력
orders, lines, pays = {}, [], []
heap, seq = [], 0
next_ord = [max_ord + 1]


def push(t, kind, **kw):
    global seq
    if t <= END:
        heapq.heappush(heap, (t, seq, kind, kw))
        seq += 1


def move(t, s, o, stat, typ, qty, ord_id=None, rsn=None):
    """재고 변동 1건: 매장재고 반영 + 이력 기록"""
    key = (s, o, stat)
    stock[key] = stock.get(key, 0) + qty
    last_chg[key] = t
    hist.append((t, s, o, ord_id, stat, typ, qty, rsn))


def avail(s, o):
    return stock.get((s, o, "AVAIL"), 0)


def new_order(t, s, chnl, mbr, items):
    """주문·주문상세·결제 생성. items = [(prd_opt_id, qty)]"""
    oid = next_ord[0]; next_ord[0] += 1
    disc = Decimal("0.8") if in_sale(t.date()) else Decimal("1")
    ship = None
    if chnl == "STORE_SHIP" and mbr:
        ship = (mbr[3], mbr[1], mbr[2])
    orders[oid] = dict(ord_id=oid, mbr_id=mbr[0] if mbr else None, str_id=s, sale_chnl_cd=chnl,
                       ord_stat_cd="RECEIVED" if chnl == "STORE" else "PAID", ord_dtm=t,
                       pay_aprv_dtm=t, pack_cmpl_dtm=None, prcl_hndv_dtm=None,
                       rcv_cmpl_dtm=t if chnl == "STORE" else None,
                       est_rcv_dt=t.date() if chnl == "STORE_SHIP" else None, cncl_dtm=None,
                       shpto=ship)
    total = Decimal("0")
    for n, (o, q) in enumerate(items, start=1):
        up = q2(price[o] * disc)
        lines.append((oid, n, o, q, up, Decimal("0.00")))
        total += up * q
    # 결제: 대부분 1건, 5%는 카드 + 상품권 복수 결제 (D-014)
    mthd = rng.choices(["CREDIT", "DEBIT", "CASH"] if chnl == "STORE" else ["CREDIT", "DEBIT"],
                       weights=[6, 2, 2] if chnl == "STORE" else [8, 2])[0]
    if total > 20 and rng.random() < 0.05:
        v = q2(min(Decimal("10"), total / 2))
        pays.append((oid, 1, mthd, 1, total - v)); pays.append((oid, 2, "VOUCHER", 1, v))
    else:
        pays.append((oid, 1, mthd, rng.choice([1, 1, 1, 2, 3]) if mthd == "CREDIT" else 1, total))
    return oid


def pick_items(s, max_lines, max_qty):
    """판매 가능 재고가 있는 SKU만 고른다. 없으면 빈 목록"""
    cands = [o for o in rng.sample(store_skus[s], min(15, len(store_skus[s]))) if avail(s, o) > 0]
    items = []
    for o in cands[:rng.randint(1, max_lines)]:
        q = min(rng.randint(1, max_qty), avail(s, o))
        items.append((o, q))
    return items


# 개점 초기 입고 + 테스터 전환 (D-003)
for st in stores:
    s, t0 = st["str_id"], datetime.combine(st["open_dt"], datetime.min.time()).replace(hour=9)
    for o in store_skus[s]:
        move(t0, s, o, "AVAIL", "IN", rng.randint(20, 40))
        if rng.random() < 0.3:
            move(t0 + timedelta(minutes=30), s, o, "AVAIL", "TESTER_IN", -1)
            move(t0 + timedelta(minutes=30), s, o, "TESTER", "TESTER_IN", 1)

# 날짜별 이벤트 예약
d = START.date()
while d <= END.date():
    for st in stores:
        s = st["str_id"]
        push(datetime(d.year, d.month, d.day, 9), "restock", s=s)
        for _ in range(poisson(STORE_SALE_PER_DAY * (1.5 if in_sale(d) else 1))):
            push(rand_time_on(d), "store_sale", s=s)
        mult = 3 if in_sale(d) else 1
        for _ in range(poisson(PICKUP_PER_DAY * mult)):
            push(START.replace(year=d.year, month=d.month, day=d.day) + timedelta(seconds=rng.randint(0, 86399)),
                 "online", s=s, chnl="PICKUP")
        for _ in range(poisson(SHIP_PER_DAY * mult)):
            push(rand_time_on(d), "online", s=s, chnl="STORE_SHIP")
        if (d + timedelta(days=1)).day == 1:                     # 매월 말일 재고 실사
            push(datetime(d.year, d.month, d.day, 21), "count", s=s)
        if rng.random() < 0.03:                                   # 파손 폐기
            push(rand_time_on(d), "dispose", s=s)
    d += timedelta(days=1)

# 이벤트 처리
while heap:
    t, _, kind, kw = heapq.heappop(heap)
    s = kw.get("s")

    if kind == "restock":                                         # 정기 입고: 가용 8개 미만 SKU 보충
        for o in store_skus[s]:
            if avail(s, o) < 8:
                move(t, s, o, "AVAIL", "IN", 24)

    elif kind == "store_sale":                                    # 매장판매: 즉시 가용 차감
        items = pick_items(s, 3, 2)
        if not items:
            continue
        joined = [m for m in store_mbrs if m[1] <= t and m[2] == s]
        mbr = None
        if joined and rng.random() < MEMBER_RATE_STORE:
            m = rng.choice(joined); mbr = (m[0], None, None, None)
        oid = new_order(t, s, "STORE", mbr, items)
        for o, q in items:
            move(t, s, o, "AVAIL", "SALE", -q, oid)
        if rng.random() < 0.01:                                   # 반품
            o, q = items[0]
            push(next_open(t + timedelta(days=rng.randint(1, 7))), "return", s=s, o=o, q=q, oid=oid)

    elif kind == "return":
        move(t, s, kw["o"], "AVAIL", "RETURN", kw["q"], kw["oid"])

    elif kind == "online":                                        # 픽업·매장출고: 주문 시점 할당 (가용 → 주문보관)
        items = pick_items(s, 2, 1)
        if not items:
            continue
        oid = new_order(t, s, kw["chnl"], rng.choice(local_mbrs[s]), items)
        for o, q in items:
            move(t, s, o, "AVAIL", "ORD_ALLOC", -q, oid)
            move(t, s, o, "ORD_HOLD", "ORD_ALLOC", q, oid)
        if rng.random() < CANCEL_BEFORE_PACK:
            push(t + timedelta(minutes=rng.randint(5, 90)), "cancel", s=s, oid=oid, items=items)
        else:
            push(next_open(t + timedelta(minutes=rng.randint(20, 180))), "pack", s=s, oid=oid, items=items)

    elif kind == "pack":
        od = orders[kw["oid"]]
        if od["ord_stat_cd"] == "CANCELED":
            continue
        od["pack_cmpl_dtm"], od["ord_stat_cd"] = t, "PACKED"
        rate = CANCEL_AFTER_PACK_SALE if in_sale(t.date()) else CANCEL_AFTER_PACK
        if rng.random() < rate:                                    # 포장완료 후 취소 (D-006): 마감 후 취소도 발생
            push(t + timedelta(minutes=rng.randint(60, 30 * 60)), "cancel", **kw)
        elif od["sale_chnl_cd"] == "PICKUP":
            push(next_open(t + timedelta(minutes=rng.randint(60, 48 * 60))), "receive", **kw)
        else:
            push(t + timedelta(minutes=rng.randint(30, 90)), "handover", **kw)

    elif kind == "cancel":                                        # 취소: 주문보관 → 가용 즉시 복원 (D-006)
        od = orders[kw["oid"]]
        od["ord_stat_cd"], od["cncl_dtm"] = "CANCELED", t
        for o, q in kw["items"]:
            move(t, s, o, "ORD_HOLD", "ORD_CNCL", -q, od["ord_id"])
            move(t, s, o, "AVAIL", "ORD_CNCL", q, od["ord_id"])

    elif kind == "receive":                                       # 픽업 수령
        od = orders[kw["oid"]]
        od["ord_stat_cd"], od["rcv_cmpl_dtm"] = "RECEIVED", t
        for o, q in kw["items"]:
            move(t, s, o, "ORD_HOLD", "ORD_RCV", -q, od["ord_id"])

    elif kind == "handover":                                      # 매장출고배송: 택배 인계 시 재고가 매장을 떠남
        od = orders[kw["oid"]]
        od["prcl_hndv_dtm"], od["ord_stat_cd"] = t, "SHIPPED"
        for o, q in kw["items"]:
            move(t, s, o, "ORD_HOLD", "ORD_RCV", -q, od["ord_id"])
        rcv = t + timedelta(minutes=rng.randint(90, 300))
        if rcv <= END:
            od["ord_stat_cd"], od["rcv_cmpl_dtm"] = "RECEIVED", rcv

    elif kind == "dispose":
        cands = [o for o in store_skus[s] if avail(s, o) > 0]
        if cands:
            move(t, s, rng.choice(cands), "AVAIL", "DISPOSE", -1)

    elif kind == "count":                                         # 월말 실사 (D-007, D-008)
        for o in store_skus[s]:
            if avail(s, o) <= 0 or rng.random() > 0.03:
                continue
            p = rng.random()
            if p < 0.45:      # 못 찾아서 '포스오류'로 차감 → 2일 안에 찾아서 복원
                move(t, s, o, "AVAIL", "ADJ", -1, None, "POS_ERR")
                push(next_open(t + timedelta(hours=rng.randint(12, 44))), "restore", s=s, o=o)
            elif p < 0.55:    # 원인미상으로 차감 → 2일이 지나서 발견
                move(t, s, o, "AVAIL", "ADJ", -1, None, "UNKNOWN")
                push(next_open(t + timedelta(days=rng.randint(4, 10))), "restore", s=s, o=o)
            elif p < 0.80:
                move(t, s, o, "AVAIL", "ADJ", -1, None, "THEFT")
            elif p < 0.95:
                move(t, s, o, "AVAIL", "ADJ", -1, None, "POS_ERR")
            else:
                move(t, s, o, "AVAIL", "ADJ", -1, None, "DAMAGE")

    elif kind == "restore":
        move(t, s, kw["o"], "AVAIL", "ADJ", 1, None, "FOUND")

# ---------------------------------------------------------------------
# 4. 매장재고 = 이력 누적 결과. 의도적 불일치 5행 주입
# ---------------------------------------------------------------------
stck_rows = {k: v for k, v in stock.items()}
injected = rng.sample(sorted(k for k, v in stck_rows.items() if k[2] == "AVAIL" and v > 0), 5)
for k in injected:
    stck_rows[k] -= 1                                            # 이력 없이 수량만 감소 (이력 누락 상황 가정)

# ---------------------------------------------------------------------
# 5. 적재
# ---------------------------------------------------------------------
def many(sql, rows, size=5000):
    for i in range(0, len(rows), size):
        cur.executemany(sql, rows[i:i + size])


many("INSERT INTO str (str_id, str_nm, zip_no, city_nm, st_nm, open_dt) VALUES (%s,%s,%s,%s,%s,%s)",
     [(s["str_id"], s["str_nm"], s["zip_no"], s["city_nm"], s["st_nm"], s["open_dt"]) for s in stores])

st_by_id = {s["str_id"]: s for s in stores}
many("INSERT INTO mbr (mbr_id, src_mbr_no, join_chnl_cd, join_dtm, zip_no, city_nm, st_nm) VALUES (%s,NULL,'STORE',%s,%s,%s,%s)",
     [(m, jd, st_by_id[s]["zip_no"], st_by_id[s]["city_nm"], st_by_id[s]["st_nm"]) for m, jd, s in store_mbrs])

many("""INSERT INTO ord (ord_id, mbr_id, str_id, src_ord_no, sale_chnl_cd, ord_stat_cd, ord_dtm, pay_aprv_dtm,
        pack_cmpl_dtm, prcl_hndv_dtm, rcv_cmpl_dtm, est_rcv_dt, cncl_dtm, shpto_zip_no, shpto_city_nm, shpto_st_nm)
        VALUES (%s,%s,%s,NULL,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
     [(o["ord_id"], o["mbr_id"], o["str_id"], o["sale_chnl_cd"], o["ord_stat_cd"], o["ord_dtm"], o["pay_aprv_dtm"],
       o["pack_cmpl_dtm"], o["prcl_hndv_dtm"], o["rcv_cmpl_dtm"], o["est_rcv_dt"], o["cncl_dtm"],
       *(o["shpto"] or (None, None, None))) for o in sorted(orders.values(), key=lambda x: x["ord_id"])])

many("INSERT INTO ord_dtl (ord_id, ord_dtl_seq, prd_opt_id, ord_qty, sale_uprc, ship_fee) VALUES (%s,%s,%s,%s,%s,%s)", lines)
many("INSERT INTO pay (ord_id, pay_seq, pay_mthd_cd, instl_mon_cnt, pay_amt) VALUES (%s,%s,%s,%s,%s)", pays)

many("INSERT INTO str_stck (str_id, prd_opt_id, stck_stat_cd, stck_qty, last_chg_dtm) VALUES (%s,%s,%s,%s,%s)",
     [(k[0], k[1], k[2], v, last_chg[k]) for k, v in sorted(stck_rows.items())])

hist.sort(key=lambda h: h[0])                                   # 시간순으로 재고변동ID 부여
many("""INSERT INTO stck_chg_hist (stck_chg_id, str_id, prd_opt_id, ord_id, stck_stat_cd, chg_type_cd,
        chg_qty, chg_dtm, adj_rsn_cd) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
     [(i + 1, h[1], h[2], h[3], h[4], h[5], h[6], h[0], h[7]) for i, h in enumerate(hist)])

conn.commit()

# ---------------------------------------------------------------------
# 6. 요약
# ---------------------------------------------------------------------
print(f"매장 {len(stores)}개: " + ", ".join(s["str_nm"] for s in stores))
print(f"매장 가입 회원 {len(store_mbrs):,}명")
for ch in ["STORE", "PICKUP", "STORE_SHIP"]:
    print(f"{ch:<11} 주문 {sum(1 for o in orders.values() if o['sale_chnl_cd'] == ch):,}건")
print(f"포장완료 후 취소 {sum(1 for o in orders.values() if o['cncl_dtm'] and o['pack_cmpl_dtm']):,}건")
print(f"재고변동이력 {len(hist):,}건, 매장재고 {len(stck_rows):,}행")
print("의도적 불일치 주입 (매장, SKU, 상태):", injected)
cur.close(); conn.close()
