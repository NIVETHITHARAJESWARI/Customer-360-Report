-- =====================================================================
-- Customer 360 Analytics  |  SQL model (SQLite syntax; notes for SQL Server / Postgres at bottom)
-- Layers: raw tables -> vw_txn_enriched -> vw_customer_360 -> vw_rfm -> vw_clv -> analysis queries
-- =====================================================================

-- ---------- 1. SOURCE TABLES (customer, product, transaction) ----------
DROP TABLE IF EXISTS params;
DROP TABLE IF EXISTS fact_transaction;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_customer;

CREATE TABLE params (as_of_date DATE, churn_days INTEGER);   -- reporting date + inactivity rule
INSERT INTO params VALUES ('2026-09-30', 90);

CREATE TABLE dim_customer (
    customer_id          INTEGER PRIMARY KEY,
    full_name            TEXT,
    signup_date          DATE,
    region               TEXT,
    acquisition_channel  TEXT
);
CREATE TABLE dim_product (
    product_id    INTEGER PRIMARY KEY,
    product_name  TEXT,
    category      TEXT,
    unit_price    REAL,
    unit_cost     REAL
);
CREATE TABLE fact_transaction (          -- one row per order line
    txn_id       INTEGER PRIMARY KEY,
    order_id     INTEGER,
    customer_id  INTEGER REFERENCES dim_customer(customer_id),
    product_id   INTEGER REFERENCES dim_product(product_id),
    txn_date     DATE,
    quantity     INTEGER
);
CREATE INDEX ix_txn_customer ON fact_transaction(customer_id, txn_date);

-- ---------- 2. UNIFIED MODEL ----------
-- 2a. Transactions joined to product -> revenue and margin per line
CREATE VIEW vw_txn_enriched AS
SELECT t.txn_id, t.order_id, t.customer_id, t.txn_date, t.quantity,
       p.category,
       t.quantity * p.unit_price                    AS revenue,
       t.quantity * (p.unit_price - p.unit_cost)    AS margin
FROM fact_transaction t
JOIN dim_product p USING (product_id);

-- 2b. One row per customer: profile + purchase history + product affinity (the "single view")
CREATE VIEW vw_customer_360 AS
WITH agg AS (
    SELECT customer_id,
           MIN(txn_date)               AS first_order_date,
           MAX(txn_date)               AS last_order_date,
           COUNT(DISTINCT order_id)    AS orders,
           SUM(revenue)                AS revenue,
           SUM(margin)                 AS gross_margin,
           COUNT(DISTINCT category)    AS categories_bought
    FROM vw_txn_enriched
    GROUP BY customer_id
),
fav AS (
    SELECT customer_id, category AS favourite_category
    FROM (SELECT customer_id, category,
                 ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY SUM(revenue) DESC) AS rn
          FROM vw_txn_enriched GROUP BY customer_id, category)
    WHERE rn = 1
)
SELECT c.customer_id, c.full_name, c.region, c.acquisition_channel, c.signup_date,
       a.first_order_date, a.last_order_date, a.orders, a.revenue, a.gross_margin,
       a.categories_bought, f.favourite_category,
       CAST(julianday(p.as_of_date) - julianday(a.last_order_date) AS INTEGER)       AS recency_days,
       ROUND(a.revenue * 1.0 / a.orders, 2)                                          AS avg_order_value,
       MAX(1, CAST((julianday(p.as_of_date) - julianday(a.first_order_date)) / 30.44 AS INTEGER))
                                                                                     AS tenure_months,
       CASE WHEN julianday(p.as_of_date) - julianday(a.last_order_date) > p.churn_days
            THEN 1 ELSE 0 END                                                        AS is_churned
FROM dim_customer c
JOIN agg a USING (customer_id)
JOIN fav f USING (customer_id)
CROSS JOIN params p;

-- ---------- 3. RFM SEGMENTATION ----------
-- R: fixed bands aligned to the 90-day churn rule. F: fixed bands (order counts tie heavily). M: quintiles via NTILE. 5 = best.
CREATE VIEW vw_rfm AS
WITH scored AS (
    SELECT *,
           CASE WHEN recency_days <= 30 THEN 5 WHEN recency_days <= 60 THEN 4 WHEN recency_days <= 90 THEN 3
                WHEN recency_days <= 180 THEN 2 ELSE 1 END          AS r_score,
           CASE WHEN orders >= 8 THEN 5 WHEN orders >= 5 THEN 4 WHEN orders >= 3 THEN 3
                WHEN orders = 2 THEN 2 ELSE 1 END                   AS f_score,
           NTILE(5) OVER (ORDER BY revenue, customer_id)            AS m_score
    FROM vw_customer_360
)
SELECT *,
       CASE
           WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
           WHEN r_score >= 3 AND f_score >= 4                  THEN 'Loyal'
           WHEN r_score <= 2 AND f_score >= 4                  THEN 'Cannot Lose'
           WHEN r_score <= 2 AND f_score = 3                   THEN 'At Risk'
           WHEN r_score >= 4 AND f_score = 1                   THEN 'New Customers'
           WHEN r_score >= 3 AND f_score >= 2                  THEN 'Potential Loyalists'
           WHEN r_score <= 2 AND f_score <= 2                  THEN 'Hibernating'
           ELSE 'Needs Attention'
       END AS rfm_segment
FROM scored;

-- ---------- 4. CUSTOMER LIFETIME VALUE ----------
-- Total CLV = margin earned to date + predicted future margin.
-- Predicted = monthly margin run-rate x expected remaining lifetime (months) for still-active customers.
-- Expected lifetime = 1 / monthly churn hazard of the customer's frequency band (events / exposure months),
-- floored at 1% hazard and capped at 24 months to stay conservative.
CREATE VIEW vw_clv AS
WITH hazard AS (
    SELECT f_score,
           SUM(is_churned) * 1.0 / SUM(tenure_months) AS monthly_hazard
    FROM vw_rfm GROUP BY f_score
),
base AS (
    SELECT r.*, h.monthly_hazard,
           MIN(24.0, 1.0 / MAX(h.monthly_hazard, 0.01))   AS expected_lifetime_months,
           r.gross_margin * 1.0 / r.tenure_months          AS monthly_margin
    FROM vw_rfm r JOIN hazard h USING (f_score)
)
SELECT *,
       CASE WHEN is_churned = 1 THEN 0 ELSE monthly_margin * expected_lifetime_months END AS predicted_clv,
       gross_margin + CASE WHEN is_churned = 1 THEN 0
                           ELSE monthly_margin * expected_lifetime_months END               AS total_clv
FROM base;

-- ---------- 5. ANALYSIS QUERIES (feed the Power BI report) ----------
-- name: kpis
SELECT COUNT(*)                                             AS customers,
       SUM(1 - is_churned)                                  AS active_customers,
       ROUND(AVG(is_churned) * 100, 1)                      AS churn_pct,
       ROUND(SUM(revenue))                                  AS revenue,
       ROUND(AVG(total_clv))                                AS avg_clv,
       ROUND(AVG(orders), 1)                                AS avg_orders,
       ROUND(SUM(CASE WHEN rfm_segment IN ('At Risk','Cannot Lose')
                      THEN revenue * 12.0 / tenure_months END)) AS annual_revenue_at_risk
FROM vw_clv;

-- name: segments
SELECT rfm_segment, COUNT(*) AS customers, ROUND(SUM(revenue)) AS revenue,
       ROUND(AVG(recency_days)) AS avg_recency, ROUND(AVG(orders), 1) AS avg_orders,
       ROUND(AVG(total_clv)) AS avg_clv, ROUND(SUM(total_clv)) AS total_clv,
       ROUND(AVG(is_churned) * 100, 1) AS churn_pct
FROM vw_clv GROUP BY rfm_segment ORDER BY total_clv DESC;

-- name: monthly
SELECT strftime('%Y-%m', txn_date) AS month, ROUND(SUM(revenue)) AS revenue,
       COUNT(DISTINCT customer_id) AS buyers
FROM vw_txn_enriched GROUP BY 1 ORDER BY 1;

-- name: cohort
WITH first AS (SELECT customer_id, strftime('%Y-%m', MIN(txn_date)) AS cohort
               FROM fact_transaction GROUP BY customer_id),
act AS (SELECT DISTINCT customer_id, strftime('%Y-%m', txn_date) AS m FROM fact_transaction),
j AS (SELECT f.cohort,
             (CAST(substr(a.m,1,4) AS INTEGER) - CAST(substr(f.cohort,1,4) AS INTEGER)) * 12
             + CAST(substr(a.m,6,2) AS INTEGER) - CAST(substr(f.cohort,6,2) AS INTEGER) AS k,
             COUNT(*) AS n
      FROM first f JOIN act a USING (customer_id) GROUP BY 1, 2),
sz AS (SELECT cohort, COUNT(*) AS size FROM first GROUP BY cohort)
SELECT j.cohort, j.k, sz.size, ROUND(100.0 * j.n / sz.size, 1) AS retention_pct
FROM j JOIN sz USING (cohort) WHERE j.k <= 12 ORDER BY 1, 2;

-- name: churn_region
SELECT region AS label, COUNT(*) AS customers, ROUND(AVG(is_churned) * 100, 1) AS churn_pct,
       ROUND(AVG(total_clv)) AS avg_clv
FROM vw_clv GROUP BY region ORDER BY churn_pct DESC;

-- name: churn_channel
SELECT acquisition_channel AS label, COUNT(*) AS customers, ROUND(AVG(is_churned) * 100, 1) AS churn_pct,
       ROUND(AVG(total_clv)) AS avg_clv
FROM vw_clv GROUP BY acquisition_channel ORDER BY churn_pct DESC;

-- name: churn_orders
SELECT CASE f_score WHEN 1 THEN '1 order' WHEN 2 THEN '2 orders' WHEN 3 THEN '3-4 orders'
                    WHEN 4 THEN '5-7 orders' ELSE '8+ orders' END AS label,
       COUNT(*) AS customers, ROUND(AVG(is_churned) * 100, 1) AS churn_pct
FROM vw_clv GROUP BY f_score ORDER BY f_score;

-- name: customers
SELECT customer_id, full_name, region, rfm_segment, recency_days, orders,
       ROUND(revenue) AS revenue, ROUND(total_clv) AS clv, favourite_category
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY rfm_segment ORDER BY total_clv DESC) AS rn FROM vw_clv)
WHERE rn <= 8 ORDER BY rfm_segment, rn;

-- name: cust
WITH fo AS (SELECT customer_id, strftime('%Y-%m', MIN(txn_date)) AS cohort FROM fact_transaction GROUP BY customer_id),
act AS (SELECT DISTINCT customer_id, strftime('%Y-%m', txn_date) AS m FROM fact_transaction),
mk AS (
  SELECT customer_id, SUM(1 << k) AS retention_mask   -- bit k set = bought k months after first order
  FROM (SELECT fo.customer_id,
               (CAST(substr(act.m,1,4) AS INTEGER) - CAST(substr(fo.cohort,1,4) AS INTEGER)) * 12
               + CAST(substr(act.m,6,2) AS INTEGER) - CAST(substr(fo.cohort,6,2) AS INTEGER) AS k
        FROM fo JOIN act USING (customer_id))
  WHERE k BETWEEN 0 AND 12 GROUP BY customer_id)
SELECT c.customer_id, c.full_name, c.region, c.acquisition_channel AS channel, c.rfm_segment AS segment,
       c.recency_days AS recency, c.orders, ROUND(c.revenue) AS revenue, ROUND(c.total_clv) AS clv,
       ROUND(c.predicted_clv) AS predicted, c.is_churned AS churned, c.favourite_category AS category,
       c.r_score AS r, c.f_score AS f, c.m_score AS m, fo.cohort, mk.retention_mask AS mask
FROM vw_clv c JOIN fo USING (customer_id) JOIN mk USING (customer_id);

-- name: monthly_cut
SELECT strftime('%Y-%m', t.txn_date) AS month, c.region, c.acquisition_channel AS channel,
       c.rfm_segment AS segment, ROUND(SUM(t.revenue)) AS revenue, COUNT(DISTINCT t.customer_id) AS buyers
FROM vw_txn_enriched t JOIN vw_clv c USING (customer_id) GROUP BY 1, 2, 3, 4;

-- name: category_cut
SELECT t.category, c.region, c.acquisition_channel AS channel, c.rfm_segment AS segment,
       ROUND(SUM(t.revenue)) AS revenue, ROUND(SUM(t.margin)) AS margin
FROM vw_txn_enriched t JOIN vw_clv c USING (customer_id) GROUP BY 1, 2, 3, 4;

-- ---------- PORTING NOTES ----------
-- SQL Server: julianday(a)-julianday(b) -> DATEDIFF(day,b,a); strftime('%Y-%m',d) -> FORMAT(d,'yyyy-MM');
--             MIN/MAX(a,b) scalar -> LEAST/GREATEST (2022+) or CASE; LIMIT -> TOP.
-- Postgres:   julianday diff -> (a::date - b::date); strftime -> to_char(d,'YYYY-MM'); MIN/MAX scalar -> LEAST/GREATEST.
-- Power BI:   import vw_clv (plus vw_txn_enriched, dim_customer) via DirectQuery/Import; the DAX measures
--             mirror the KPI query: Churn % = AVERAGE(vw_clv[is_churned]), Avg CLV = AVERAGE(vw_clv[total_clv]).
