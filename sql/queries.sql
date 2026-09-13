-- ============================================================
-- CRM Sales Pipeline Analysis — SQL Queries
-- Dataset: Kaggle "CRM Sales Opportunities"
-- Engine: MySQL / MariaDB
-- ============================================================


-- ============================================================
-- SECTION 1: SCHEMA — TABLE CREATION WITH KEYS
-- ============================================================

CREATE DATABASE crm_sales_opportunities;
USE crm_sales_opportunities;

-- Parent table. Self-referencing FK for subsidiary_of.
CREATE TABLE accounts (
    account_id       VARCHAR(10)   PRIMARY KEY,
    account          VARCHAR(100)  NOT NULL UNIQUE,
    sector           VARCHAR(50),
    year_established INT,
    revenue          DECIMAL(10,2),
    employees        INT,
    office_location  VARCHAR(100),
    subsidiary_of    VARCHAR(100),
    FOREIGN KEY (subsidiary_of) REFERENCES accounts(account)
);

CREATE TABLE products (
    product      VARCHAR(50) PRIMARY KEY,
    series       VARCHAR(20),
    sales_price  DECIMAL(10,2)
);

CREATE TABLE sales_teams (
    sales_agent      VARCHAR(100) PRIMARY KEY,
    manager          VARCHAR(100),
    regional_office  VARCHAR(50)
);

-- Fact table. FKs to all three dimension tables above.
CREATE TABLE sales_pipeline (
    opportunity_id VARCHAR(20)  PRIMARY KEY,
    sales_agent    VARCHAR(100) NOT NULL,
    product        VARCHAR(50)  NOT NULL,
    account        VARCHAR(100),
    account_id     VARCHAR(10),
    deal_stage     VARCHAR(20)  NOT NULL,
    engage_date    DATE,
    close_date     DATE,
    close_value    DECIMAL(10,2),
    FOREIGN KEY (sales_agent) REFERENCES sales_teams(sales_agent),
    FOREIGN KEY (product)     REFERENCES products(product),
    FOREIGN KEY (account_id)  REFERENCES accounts(account_id)
);


-- ============================================================
-- SECTION 2: DATA CLEANING
-- ============================================================

-- 2.1 Product naming mismatch: raw pipeline data had "GTXPro"
-- (no space) while products table had "GTX Pro" — would have
-- silently broken any join to pull in sales_price.
UPDATE sales_pipeline SET product = 'GTX Pro' WHERE product = 'GTXPro';

-- 2.2 FK import failure: blank subsidiary_of cells loaded as
-- empty string '' rather than NULL, which fails the FK check
-- (NULL is exempt from FK checks, '' is not). Fixed after
-- temporarily dropping the constraint, importing, then:
UPDATE accounts SET subsidiary_of = NULL WHERE subsidiary_of = '';

-- Check for any remaining unmatched subsidiary_of values
-- before re-adding the FK constraint:
SELECT DISTINCT subsidiary_of
FROM accounts a
WHERE subsidiary_of IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM accounts a2 WHERE a2.account = a.subsidiary_of
);

-- Re-add the FK constraint once clean:
ALTER TABLE accounts
ADD CONSTRAINT accounts_ibfk_1
FOREIGN KEY (subsidiary_of) REFERENCES accounts(account);

-- 2.3 Push the new surrogate account_id from accounts into
-- sales_pipeline (MySQL/MariaDB JOIN-UPDATE syntax):
ALTER TABLE sales_pipeline ADD account_id VARCHAR(10);

UPDATE sales_pipeline sp
JOIN accounts a ON sp.account = a.account
SET sp.account_id = a.account_id;

-- Check for orphaned rows (account names with no match) —
-- these would silently get a blank account_id:
SELECT DISTINCT sp.account
FROM sales_pipeline sp
LEFT JOIN accounts a ON sp.account = a.account
WHERE a.account IS NULL;


-- ============================================================
-- SECTION 3: Q1 — AGENT & REGIONAL PERFORMANCE
-- ============================================================

-- 3.1 Regional performance (win rate = closed deals only,
-- i.e. Won / (Won + Lost), not Won / all pipeline activity)
SELECT
    st.regional_office,
    COUNT(s.opportunity_id) AS total_deals,
    COUNT(CASE WHEN s.deal_stage = 'Won' THEN 1 END) AS total_wins,
    (COUNT(CASE WHEN s.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN s.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate,
    SUM(s.close_value) AS total_revenue,
    AVG(CASE WHEN s.deal_stage = 'Won' THEN s.close_value END) AS avg_deal_size,
    AVG(DATEDIFF(close_date, engage_date)) AS avg_sales_cycle
FROM sales_pipeline s
JOIN sales_teams st ON s.sales_agent = st.sales_agent
GROUP BY st.regional_office
ORDER BY total_deals DESC;

-- 3.2 Agent-level performance (same measures, per agent)
SELECT
    s.sales_agent,
    COUNT(s.opportunity_id) AS total_deals,
    COUNT(CASE WHEN s.deal_stage = 'Won' THEN 1 END) AS total_wins,
    (COUNT(CASE WHEN s.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN s.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate,
    SUM(close_value) AS total_revenue,
    AVG(CASE WHEN s.deal_stage = 'Won' THEN s.close_value END) AS avg_deal_size,
    AVG(DATEDIFF(close_date, engage_date)) AS avg_sales_cycle
FROM sales_pipeline s
GROUP BY s.sales_agent
ORDER BY total_deals DESC;


-- ============================================================
-- SECTION 4: Q2 — PIPELINE DROP-OFF & QUARTER-END PATTERN
-- ============================================================

-- 4.1 Baseline funnel shape: count of opportunities per stage
SELECT deal_stage, COUNT(opportunity_id) AS deal_count
FROM sales_pipeline
GROUP BY deal_stage
ORDER BY deal_count DESC;

-- 4.2 Lost-deal analysis by product, using each product's own
-- historical average Won price (more defensible than list
-- price) to estimate opportunity cost of lost deals
SELECT
    sp.product,
    COUNT(sp.opportunity_id) AS lost_count,
    (SELECT AVG(close_value) FROM sales_pipeline
        WHERE product = sp.product AND deal_stage = 'Won') AS avg_won_price,
    COUNT(sp.opportunity_id) *
        (SELECT AVG(close_value) FROM sales_pipeline
            WHERE product = sp.product AND deal_stage = 'Won') AS estimated_lost_value
FROM sales_pipeline sp
WHERE sp.deal_stage = 'Lost'
GROUP BY sp.product
ORDER BY estimated_lost_value DESC;

-- 4.3 Same lost-deal pattern check, by agent
SELECT
    sp.sales_agent,
    COUNT(CASE WHEN sp.deal_stage = 'Lost' THEN 1 END) AS lost_count,
    (SELECT AVG(close_value) FROM sales_pipeline
        WHERE sales_agent = sp.sales_agent AND deal_stage = 'Won') AS avg_won_price,
    (COUNT(CASE WHEN sp.deal_stage = 'won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN sp.deal_stage IN ('won','lost') THEN 1 END), 0) AS win_rate
FROM sales_pipeline sp
GROUP BY sp.sales_agent
ORDER BY lost_count DESC;

-- 4.4 Quarter-end seasonality check: does average sales cycle
-- differ between deals that closed in a quarter-end month vs.
-- other months? (headline finding of the project)
SELECT
    CASE WHEN close_date LIKE '2017-03%' OR close_date LIKE '2017-06%'
              OR close_date LIKE '2017-09%' OR close_date LIKE '2017-12%'
         THEN 'Quarter-End Month' ELSE 'Other Month' END AS period,
    COUNT(*) AS won_deals,
    AVG(DATEDIFF(close_date, engage_date)) AS avg_cycle_days
FROM sales_pipeline
WHERE deal_stage = 'Won'
GROUP BY period;

-- 4.5 Confirm the quarter-end pattern holds per-agent, not just
-- in aggregate (i.e. it's a structural pattern, not a few
-- individuals skewing the average)
SELECT
    sp.sales_agent,
    SUM(CASE WHEN (close_date LIKE '2017-03%' OR close_date LIKE '2017-06%'
                   OR close_date LIKE '2017-09%' OR close_date LIKE '2017-12%')
              AND deal_stage = 'Won' THEN 1 ELSE 0 END) AS qe_won,
    SUM(CASE WHEN (close_date LIKE '2017-03%' OR close_date LIKE '2017-06%'
                   OR close_date LIKE '2017-09%' OR close_date LIKE '2017-12%')
              AND deal_stage IN ('Won','Lost') THEN 1 ELSE 0 END) AS qe_total,
    SUM(CASE WHEN NOT (close_date LIKE '2017-03%' OR close_date LIKE '2017-06%'
                       OR close_date LIKE '2017-09%' OR close_date LIKE '2017-12%')
              AND deal_stage = 'Won' THEN 1 ELSE 0 END) AS other_won,
    SUM(CASE WHEN NOT (close_date LIKE '2017-03%' OR close_date LIKE '2017-06%'
                       OR close_date LIKE '2017-09%' OR close_date LIKE '2017-12%')
              AND deal_stage IN ('Won','Lost') THEN 1 ELSE 0 END) AS other_total
FROM sales_pipeline sp
WHERE deal_stage IN ('Won','Lost')
GROUP BY sp.sales_agent;


-- ============================================================
-- SECTION 5: Q3 — PRODUCT & SECTOR REVENUE
-- ============================================================

-- 5.1 Product-level win rate and deal count
SELECT
    s.product,
    COUNT(s.opportunity_id) AS total_deals,
    COUNT(CASE WHEN s.deal_stage IN ('Won','Lost') THEN 1 END) AS completed_deals,
    (COUNT(CASE WHEN s.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN s.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate
FROM sales_pipeline s
GROUP BY s.product
ORDER BY total_deals DESC;

-- 5.2 Sector-level performance (joins to accounts for sector)
SELECT
    a.sector,
    COUNT(sp.opportunity_id) AS total_deals,
    (COUNT(CASE WHEN sp.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN sp.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate,
    AVG(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS avg_deal_size,
    SUM(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS total_revenue
FROM sales_pipeline sp
JOIN accounts a ON sp.account = a.account
GROUP BY a.sector
ORDER BY total_revenue DESC;


-- ============================================================
-- SECTION 6: Q4 — ACCOUNT SIZE VS. OUTCOME
-- ============================================================

-- 6.1 Split accounts into 3 equal-sized revenue tiers using
-- NTILE (percentile-based, not fixed dollar ranges — revenue
-- is heavily right-skewed, so equal-width buckets would put
-- nearly everyone in "Small")
SELECT
    acct_tier.revenue_tier,
    COUNT(sp.opportunity_id) AS total_deals,
    (COUNT(CASE WHEN sp.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN sp.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate,
    AVG(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS avg_deal_size,
    SUM(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS total_revenue
FROM sales_pipeline sp
JOIN (
    SELECT account,
           CASE NTILE(3) OVER (ORDER BY revenue)
               WHEN 1 THEN 'Small'
               WHEN 2 THEN 'Medium'
               WHEN 3 THEN 'Large'
           END AS revenue_tier
    FROM accounts
) AS acct_tier ON sp.account = acct_tier.account
GROUP BY acct_tier.revenue_tier
ORDER BY total_revenue DESC;

-- 6.2 Revenue concentration check: what % of total account
-- revenue sits in the top 10 accounts? (justifies treating
-- them as a distinct "whale" segment rather than folding them
-- into a standard size tier)
SELECT
    (SELECT SUM(revenue) FROM (
        SELECT revenue FROM accounts ORDER BY revenue DESC LIMIT 10
    ) AS top10) AS top10_revenue,
    (SELECT SUM(revenue) FROM accounts) AS total_revenue,
    (SELECT SUM(revenue) FROM (
        SELECT revenue FROM accounts ORDER BY revenue DESC LIMIT 10
    ) AS top10) / (SELECT SUM(revenue) FROM accounts) * 100 AS pct_of_total;

-- 6.3 Whale (top 10) vs. Standard account comparison — the
-- project's strongest finding. LIMIT is wrapped in its own
-- derived table since MariaDB doesn't support LIMIT directly
-- inside an IN (...) subquery.
SELECT
    CASE WHEN sp.account IN (
        SELECT account FROM (
            SELECT account FROM accounts ORDER BY revenue DESC LIMIT 10
        ) AS top10
    ) THEN 'Whale (Top 10)' ELSE 'Standard' END AS account_segment,
    COUNT(sp.opportunity_id) AS total_deals,
    (COUNT(CASE WHEN sp.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN sp.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate,
    AVG(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS avg_deal_size,
    SUM(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS total_revenue
FROM sales_pipeline sp
GROUP BY account_segment;

-- 6.4 Cross-check: re-run the NTILE(3) tiering excluding the
-- top 10 whales, to confirm the under-penetration pattern
-- holds even among "normal" accounts, not just at the extreme
SELECT
    acct_tier.revenue_tier,
    COUNT(sp.opportunity_id) AS total_deals,
    (COUNT(CASE WHEN sp.deal_stage = 'Won' THEN 1 END) * 100.0)
        / NULLIF(COUNT(CASE WHEN sp.deal_stage IN ('Won','Lost') THEN 1 END), 0) AS win_rate,
    AVG(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS avg_deal_size,
    SUM(CASE WHEN sp.deal_stage = 'Won' THEN sp.close_value END) AS total_revenue
FROM sales_pipeline sp
JOIN (
    SELECT account,
           CASE NTILE(3) OVER (ORDER BY revenue)
               WHEN 1 THEN 'Small'
               WHEN 2 THEN 'Medium'
               WHEN 3 THEN 'Large'
           END AS revenue_tier
    FROM accounts
    WHERE account NOT IN (
        SELECT account FROM (
            SELECT account FROM accounts ORDER BY revenue DESC LIMIT 10
        ) AS top10
    )
) AS acct_tier ON sp.account = acct_tier.account
GROUP BY acct_tier.revenue_tier
ORDER BY total_revenue DESC;
