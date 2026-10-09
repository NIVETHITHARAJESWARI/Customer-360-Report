"""Generate synthetic retail data, run customer360.sql, export results to dashboard_data.json."""
import json, math, random, re, sqlite3, datetime as dt
from pathlib import Path

random.seed(42)
HERE = Path(__file__).parent
START, ASOF = dt.date(2024, 10, 1), dt.date(2026, 9, 30)
REGIONS = ["Chennai", "Bengaluru", "Mumbai", "Delhi NCR", "Hyderabad"]
CHANNELS = {"Organic search": 0.8, "Referral": 0.7, "Email": 0.9, "Marketplace": 1.1, "Paid social": 1.5}
CATS = {"Grocery": (120, 900), "Home & Kitchen": (400, 5000), "Apparel": (500, 4000),
        "Electronics": (1500, 25000), "Beauty": (200, 2500), "Sports": (600, 6000)}
TYPES = [("loyal", .18, 1.2, .008), ("regular", .32, .7, .02), ("occasional", .30, .45, .04), ("one-time", .20, .0, .5)]
FIRST = "Arun Priya Karthik Divya Suresh Meena Rahul Anita Vikram Kavya Imran Sneha Rohan Nisha Aditya Pooja Manoj Lakshmi".split()
LAST = "Kumar Sharma Iyer Reddy Nair Patel Singh Menon Rao Das Gupta Khan Pillar Joshi Naidu Verma".split()


def poisson(lam):
    L, k, p = math.exp(-lam), 0, 1.0
    while p > L:
        k += 1; p *= random.random()
    return k - 1


def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    return dt.date(d.year + y, m + 1, 1)


db = sqlite3.connect(":memory:")
sql = (HERE / "customer360.sql").read_text()
parts = re.split(r"^-- name: (\w+)\s*$", sql, flags=re.M)
db.executescript(parts[0])

products = []
for cat, (lo, hi) in CATS.items():
    for i in range(7):
        price = round(random.uniform(lo, hi), -1)
        products.append((len(products) + 1, f"{cat} item {i + 1}", cat, price, round(price * random.uniform(.55, .8), 0)))
db.executemany("INSERT INTO dim_product VALUES (?,?,?,?,?)", products)
by_cat = {c: [p for p in products if p[2] == c] for c in CATS}

N, order_id, txn_id, custs, txns = 3200, 0, 0, [], []
for cid in range(1, N + 1):
    signup = START + dt.timedelta(days=int(random.random() ** 1.15 * 720))
    region, channel = random.choice(REGIONS), random.choices(list(CHANNELS), [30, 15, 15, 20, 20])[0]
    custs.append((cid, f"{random.choice(FIRST)} {random.choice(LAST)}", signup.isoformat(), region, channel))
    _, _, rate, hz = random.choices(TYPES, [t[1] for t in TYPES])[0]
    hz = min(.9, hz * CHANNELS[channel] * (1.2 if region == "Delhi NCR" else 1))
    favs = random.sample(list(CATS), 2)
    month, dates = dt.date(signup.year, signup.month, 1), [signup]
    if rate == 0 and random.random() < .15:
        dates.append(min(ASOF, signup + dt.timedelta(days=random.randint(10, 60))))
    month = add_months(month, 1)
    alive = rate > 0
    while alive and month <= ASOF:
        if random.random() < hz:
            break
        for _ in range(poisson(rate)):
            d = month + dt.timedelta(days=random.randint(0, 27))
            if d <= ASOF: dates.append(d)
        month = add_months(month, 1)
    for d in dates:
        order_id += 1
        for _ in range(random.choice([1, 1, 2, 3])):
            cat = random.choice(favs) if random.random() < .7 else random.choice(list(CATS))
            txn_id += 1
            txns.append((txn_id, order_id, cid, random.choice(by_cat[cat])[0], d.isoformat(),
                         random.choice([1, 1, 1, 2, 3]) if cat in ("Grocery", "Beauty") else random.choice([1, 1, 2])))
db.executemany("INSERT INTO dim_customer VALUES (?,?,?,?,?)", custs)
db.executemany("INSERT INTO fact_transaction VALUES (?,?,?,?,?,?)", txns)

out = {}
for name, query in zip(parts[1::2], parts[2::2]):
    cur = db.execute(query)
    cols = [c[0] for c in cur.description]
    rows = cur.fetchall()
    out[name] = {"cols": cols, "rows": [list(r) for r in rows]} if name in ("cust", "monthly_cut", "category_cut") \
        else [dict(zip(cols, r)) for r in rows]
out["kpis"] = out["kpis"][0]
(HERE / "dashboard_data.json").write_text(json.dumps(out, separators=(",", ":")))
print(f"{N} customers, {len(txns)} order lines, {order_id} orders")
print(json.dumps(out["kpis"]))
for s in out["segments"]: print(s)
for k in ("churn_region", "churn_channel", "churn_orders"): print(k, out[k])

# Build the dashboard page from the fresh data and open it in the browser
import build_dashboard
build_dashboard.build()
