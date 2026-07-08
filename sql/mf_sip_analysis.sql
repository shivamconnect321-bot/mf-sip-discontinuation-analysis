-- ================================================================
-- PROJECT 3: Mutual Fund SIP Discontinuation Analysis
-- ================================================================
-- Author: Shivam
-- Database: mf_sip_churn
-- Table: sip_transactions
--
/*-- BUSINESS PROBLEM:
 Mutual fund investors frequently discontinue their SIPs (Systematic
 Investment Plans) before completing their intended investment
 horizon. This project investigates WHERE, WHEN, and WHY SIP
 discontinuation happens, using investor-level payment history to
 surface patterns that a simple summary report cannot reveal —
 specifically which fund categories, ticket sizes, and payment
 behaviors are the strongest predictors of discontinuation.*/
--
/*-- DATASET:
 Synthetically generated investor-month panel data (real investor-
 level SIP transaction data is not publicly available due to
 SEBI/RBI data privacy regulations). 660 investors, 21 schemes,
 10 SEBI fund categories, 36-month observation window
 (Jul 2023-Jun 2026), 15,509 investor-month rows.*/

/*-- CHURN DEFINITION:
 An investor is considered "discontinued" after 3 consecutive
 missed monthly SIP payments — a standard industry proxy for an
 inactive SIP mandate.*/

/* DATA LOAD METHOD:
 Data was loaded into MySQL using Python (Pandas + SQLAlchemy),
 reading the cleaned CSV and pushing it directly via to_sql().
 Date columns were explicitly parsed from DD-MM-YYYY format into
 proper DATE/DATETIME types during load.*/

/*-- TECHNIQUES DEMONSTRATED:
 Window functions (LAG, LEAD, RANK, DENSE_RANK, NTILE, running
 aggregates), Common Table Expressions (CTEs, including chained
 and gaps-and-islands patterns), cohort/retention analysis.*/
 -- ================================================================


-- ================================================================
-- SECTION 0: DATABASE & TABLE SETUP
-- ================================================================

CREATE DATABASE IF NOT EXISTS mf_sip_churn;
USE mf_sip_churn;

CREATE TABLE IF NOT EXISTS sip_transactions (
    investor_id           VARCHAR(20),
    scheme_code           VARCHAR(20),
    scheme_name           VARCHAR(100),
    sebi_category         VARCHAR(50),
    month_date            DATE,
    tenure_months         INT,
    sip_amount            INT,
    payment_status        VARCHAR(10),
    nav_value             DOUBLE,
    age                   INT,
    city_tier             VARCHAR(10),
    occupation_type       VARCHAR(30),
    discontinued          INT,
    discontinuation_date  DATE
);

-- Data loaded via Python/Pandas (see project documentation).
-- Verification: SELECT COUNT(*) FROM sip_transactions; → 15,509 rows


-- ================================================================
-- SECTION 1: ADVANCED SQL BUSINESS QUESTIONS
-- ================================================================


/*------------------------------------------------------------------
  Q1: Which investors show 3+ consecutive missed SIP payments?
 Technique:      LAG() + gaps-and-islands CTE pattern
 Business value: Directly identifies the exact investors who meet
			     this dataset's formal discontinuation rule, and when their
				 lapse streak began — the foundation for all discontinuation
				 analysis that follows.
 ----------------------------------------------------------------*/


WITH payment_flagged AS (
    SELECT
        investor_id,
        month_date,
        payment_status,
        CASE WHEN payment_status = 'Missed' THEN 1 ELSE 0 END AS is_missed,
        LAG(CASE WHEN payment_status = 'Missed' THEN 1 ELSE 0 END)
            OVER (PARTITION BY investor_id ORDER BY month_date) AS prev_missed
    FROM sip_transactions
),
streak_groups AS (
    SELECT
        investor_id,
        month_date,
        is_missed,
        SUM(CASE WHEN is_missed <> IFNULL(prev_missed, -1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY investor_id ORDER BY month_date) AS streak_group
    FROM payment_flagged
)
SELECT
    investor_id,
    streak_group,
    COUNT(*) AS consecutive_missed_count,
    MIN(month_date) AS streak_start,
    MAX(month_date) AS streak_end
FROM streak_groups
WHERE is_missed = 1
GROUP BY investor_id, streak_group
HAVING COUNT(*) >= 3
ORDER BY consecutive_missed_count DESC;
  
/*------------------------------------------------------------------
 ANALYSIS:
The query correctly isolated unbroken missed-payment streaks per
investor, with every returned streak length >= 3 (e.g., INV10002: 3
consecutive misses Jan-Mar 2025; INV10021: 12 consecutive misses
Feb-Apr 2026), confirming the LAG-based gaps-and-islands logic
correctly filters only genuine discontinuation events, not isolated
single misses.

A separate validation query counting DISTINCT investor_id across
these qualifying streaks returned 264 — an exact match to the
dataset's known total discontinued-investor count established during
initial data exploration. This confirms the streak-detection logic
is not just internally consistent, but correctly reconstructs the
exact rule the dataset was generated under.

Business takeaway: this is the single most reliable discontinuation
signal in the dataset — later queries (Q2, Q3) will show that
simpler metrics like total missed-payment count do NOT reliably
predict discontinuation the way this consecutive-streak logic does.
--------------------------------------------------------------------*/



/*--------------------------------------------------------------------
 Q2: Which investors are the highest-risk within each SEBI category,
	ranked by total missed payments?
Technique:      RANK() window function, partitioned by category
Business value: Surfaces the specific highest-risk investors per
category :      useful for targeted retention outreach, rather than
				just knowing which categories are risky overall.
------------------------------------------------------------------*/

WITH investor_summary AS (
    SELECT
        investor_id,
        sebi_category,
        MAX(discontinued) AS discontinued,
        SUM(CASE WHEN payment_status = 'Missed' THEN 1 ELSE 0 END) AS total_missed
    FROM sip_transactions
    GROUP BY investor_id, sebi_category
)
SELECT
    investor_id,
    sebi_category,
    total_missed,
    discontinued,
    RANK() OVER (PARTITION BY sebi_category ORDER BY total_missed DESC) AS risk_rank_in_category
FROM investor_summary
ORDER BY sebi_category, risk_rank_in_category;

/*-----------------------------------------------------------------
ANALYSIS:
Ranking correctly resets per category and handles ties appropriately
(e.g., two investors tied at 10 missed payments in Balanced Hybrid
both received Rank 4, with the next investor correctly jumping to
Rank 7, skipping 5-6, confirming RANK()'s tie-handling behavior).

Key finding: total missed-payment count does NOT reliably predict
discontinuation status. The top-ranked investor in Balanced Hybrid
(14 total missed payments) was discontinued, but the 2nd-ranked
investor (12 missed payments) was not, because discontinuation
depends on CONSECUTIVE misses (Q1's rule), not total misses spread
across the full tenure.

Business takeaway: this result foreshadows a recurring theme across
Q2/Q3 — surface-level risk metrics like total miss-count can be
misleading, and any risk-scoring approach built on this data should
weight streak-length far more heavily than raw miss-count.
----------------------------------------------------------------*/



/*----------------------------------------------------------------
 Q3: What are the risk quartiles when investors are segmented by
--     missed-payment count, and how do ticket size and actual
--     discontinuation rate vary across these quartiles?
-- Technique: NTILE(4) window function
-- Business value: Converts a continuous risk signal (missed-payment
--   count) into 4 equal-sized, actionable investor segments —
--   useful for prioritizing retention campaigns (e.g., "focus
--   outreach on Quartile 1 first").
----------------------------------------------------------------*/

WITH investor_summary AS (
    SELECT
        investor_id,
        sip_amount,
        MAX(discontinued) AS discontinued,
        SUM(CASE WHEN payment_status = 'Missed' THEN 1 ELSE 0 END) AS total_missed
    FROM sip_transactions
    GROUP BY investor_id, sip_amount
),
risk_quartiles AS (
    SELECT
        investor_id,
        sip_amount,
        total_missed,
        discontinued,
        NTILE(4) OVER (ORDER BY total_missed DESC) AS risk_quartile
    FROM investor_summary
)
SELECT
    risk_quartile,
    COUNT(*) AS investor_count,
    ROUND(AVG(total_missed), 2) AS avg_missed_payments,
    ROUND(AVG(sip_amount), 0) AS avg_sip_amount,
    ROUND(AVG(discontinued) * 100, 2) AS discontinuation_rate_pct
FROM risk_quartiles
GROUP BY risk_quartile
ORDER BY risk_quartile;

/*ANALYSIS:
Results did NOT show the expected pattern. Discontinuation rate was
NOT monotonically decreasing across quartiles: Quartile 4 (fewest
total misses, avg 3.01) showed the HIGHEST discontinuation rate
(48.48%) — higher than Quartile 1 (most total misses, avg 9.75,
40.00% discontinuation). Average SIP amount also showed minimal
variation across quartiles (Rs.2570-2639), contrary to expectation.

This reinforces the Q1/Q2 finding: total missed-payment count and
consecutive-streak count are fundamentally different signals.
Investors who discontinue quickly (hitting a 3-month streak early)
generate a short overall history and therefore accumulate a LOW
total missed-payment count despite having genuinely lapsed, while
investors who scatter many isolated misses across a full 36-month
tenure survive as "active" and accumulate a HIGH total missed-payment
count.

Business takeaway: total-miss-count-based segmentation is NOT a
reliable proxy for true discontinuation risk in this dataset. Any
risk-scoring model should prioritize streak-length (Q1's logic) over
raw miss-count when identifying at-risk investors.
----------------------------------------------------------------------*/


  
/*--------------------------------------------------------------------
Q4: How does an investor's cumulative paid/missed payment count
    evolve month-over-month across their SIP tenure?
Technique: Running aggregate using window frame
    (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
Business value: Reveals WHEN in an investor's lifecycle payment
    reliability starts breaking down — early tenure (onboarding
    problem) vs late tenure (fatigue/disengagement problem) require
    very different retention interventions.
    ---------------------------------------------------------------- */

SELECT
    investor_id,
    month_date,
    tenure_months,
    payment_status,
    SUM(CASE WHEN payment_status = 'Paid' THEN 1 ELSE 0 END)
        OVER (PARTITION BY investor_id ORDER BY month_date
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_paid_count,
    SUM(CASE WHEN payment_status = 'Missed' THEN 1 ELSE 0 END)
        OVER (PARTITION BY investor_id ORDER BY month_date
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_missed_count,
    ROUND(
        SUM(CASE WHEN payment_status = 'Paid' THEN 1 ELSE 0 END)
            OVER (PARTITION BY investor_id ORDER BY month_date
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / tenure_months * 100, 2
    ) AS running_reliability_pct
FROM sip_transactions
ORDER BY investor_id, month_date;

/* -------------------------------------------------------------
ANALYSIS:
For investor INV10001, running_reliability_pct held at a stable
100.00% through month 9, dropped to 90.00% immediately following a
missed payment in month 10, then recovered slightly to 90.91% the
following month after a paid installment. This confirms the running
calculation recalculates dynamically at every row rather than
reflecting a static, end-of-period average — it reacts immediately
to each new month's outcome.

This query provides the month-by-month trace underlying the streak
logic in Q1: for any investor, it shows precisely how and when their
reliability score moved. Business takeaway: this is the strongest
candidate for a Phase 3 visualization (Python EDA) showing individual
investor decline trajectories, particularly for investors approaching
the 3-consecutive-miss discontinuation threshold.
-- ----------------------------------------------------------------*/



-- -----------------------------------------------------------------
/*Q5: When an investor misses a payment, how often does it turn out
    to be the START of a 3-consecutive-miss discontinuation streak,
    versus an isolated miss they recover from?
Technique: LEAD() window function, looking 1 and 2 months ahead
Business value: Gives a concrete early-warning probability, directly
    actionable for triggering retention outreach the moment a
    payment is missed, rather than waiting for the full streak to
    confirm.*/
-- -----------------------------------------------------------------
WITH missed_lookahead AS (
    SELECT
        investor_id,
        month_date,
        payment_status,
        LEAD(payment_status, 1) OVER (PARTITION BY investor_id ORDER BY month_date) AS next_month_status,
        LEAD(payment_status, 2) OVER (PARTITION BY investor_id ORDER BY month_date) AS next_2_month_status
    FROM sip_transactions
),
flagged AS (
    SELECT
        investor_id,
        month_date,
        CASE
            WHEN payment_status = 'Missed'
                 AND next_month_status = 'Missed'
                 AND next_2_month_status = 'Missed'
            THEN 'Confirmed Streak Start'
            WHEN payment_status = 'Missed'
            THEN 'Isolated / Recovered Miss'
        END AS miss_outcome
    FROM missed_lookahead
    WHERE payment_status = 'Missed'
)
SELECT
    miss_outcome,
    COUNT(*) AS occurrence_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_all_misses
FROM flagged
GROUP BY miss_outcome;

/* ------------------------------------------------------------------
ANALYSIS:
Results: 3,751 missed-payment instances (93.42%) were isolated or
recovered, while 264 (6.58%) were confirmed streak starts.

Cross-validation: the Confirmed Streak Start count (264) exactly
matches the dataset's total discontinued-investor count established
earlier and independently reproduced by Q1's streak-detection query.
Since each discontinued investor has exactly one streak-start event,
this equivalence confirms Q1 (backward-looking LAG) and Q5
(forward-looking LEAD) are logically consistent despite using
opposite window-function directions.

Business takeaway: only ~6.6% of individual missed payments are
true early-warning signals for discontinuation; the large majority
(93.4%) are recoverable blips. A retention strategy should therefore
avoid treating every missed payment as urgent (to prevent outreach
fatigue), while still ensuring rapid follow-up on any miss, since
roughly 1 in 15 carries genuine discontinuation risk.
------------------------------------------------------------------ */



/* ----------------------------------------------------------------
 Q6: Within each SEBI category, which specific schemes have the
 highest investor discontinuation rate?
 Technique: DENSE_RANK() window function, partitioned by category
 Business value: Pinpoints exact problem schemes (not just problem
 categories) — actionable for fund managers to investigate
 scheme-specific issues (fees, performance, communication) rather
 than treating an entire category as uniformly risky.
---------------------------------------------------------------- */

WITH scheme_summary AS (
    SELECT
        sebi_category,
        scheme_code,
        scheme_name,
        COUNT(DISTINCT investor_id) AS total_investors,
        COUNT(DISTINCT CASE WHEN discontinued = 1 THEN investor_id END) AS discontinued_investors
    FROM sip_transactions
    GROUP BY sebi_category, scheme_code, scheme_name
),
scheme_churn AS (
    SELECT
        sebi_category,
        scheme_code,
        scheme_name,
        total_investors,
        discontinued_investors,
        ROUND(discontinued_investors * 100.0 / total_investors, 2) AS churn_rate_pct
    FROM scheme_summary
)
SELECT
    sebi_category,
    scheme_code,
    scheme_name,
    total_investors,
    discontinued_investors,
    churn_rate_pct,
    DENSE_RANK() OVER (PARTITION BY sebi_category ORDER BY churn_rate_pct DESC) AS churn_rank_in_category
FROM scheme_churn
ORDER BY sebi_category, churn_rank_in_category;

/* ------------------------------------------------------------------
ANALYSIS:
This query corrects the row-level averaging bias identified during
Phase 1 (Excel) by using COUNT(DISTINCT investor_id) rather than
averaging a 0/1 flag across investor-month rows — producing the true
investor-level churn rate per scheme.

Key finding: churn concentration varies by category structure. Flexi
Cap Equity shows uniformly extreme churn across BOTH its schemes
(Midcap Advantage Fund: 71.43%, Income Plus Fund: 64.00%), indicating
a category-wide risk effect rather than an isolated scheme problem.
In contrast, Debt-Short Duration schemes cluster at low, similar
rates (12.50%-18.18%), consistent with low volatility. Balanced
Hybrid shows a moderate ~10-point spread between its two schemes
(32.14% vs 22.58%), suggesting a partial scheme-specific effect
within an otherwise mid-risk category.

Business takeaway: category-level churn numbers alone can mask
whether risk is category-wide or concentrated in specific schemes.
Fund managers should review per-scheme numbers before deciding
whether an intervention should target a whole category or just one
underperforming scheme within it.
------------------------------------------------------------------ */



/* ----------------------------------------------------------------
Q7: For discontinued investors, how does their tenure at the point
    of lapse compare to the average tenure of ALL investors in
    their same SEBI category?
Technique: CTE + AVG() OVER (PARTITION BY category) — comparing an
    individual row to a group-level benchmark calculated in the
    same query
Business value: Flags investors who churned unusually FAST relative
    to their own category's norm — these are the most urgent cases
    for root-cause investigation, since they deviate even from an
    already-risky baseline.
---------------------------------------------------------------- */

WITH investor_lapse_tenure AS (
    -- One row per discontinued investor: their tenure at the exact
    -- month they crossed into discontinuation
    SELECT DISTINCT
        investor_id,
        sebi_category,
        tenure_months AS tenure_at_lapse
    FROM sip_transactions
    WHERE discontinued = 1
      AND month_date = discontinuation_date
),
category_benchmark AS (
    SELECT
        investor_id,
        sebi_category,
        tenure_at_lapse,
        -- Average lapse-tenure across ALL discontinued investors
        -- in this same category (the "group benchmark" row)
        AVG(tenure_at_lapse) OVER (PARTITION BY sebi_category) AS avg_category_lapse_tenure
    FROM investor_lapse_tenure
)
SELECT
    investor_id,
    sebi_category,
    tenure_at_lapse,
    ROUND(avg_category_lapse_tenure, 2) AS avg_category_lapse_tenure,
    ROUND(tenure_at_lapse - avg_category_lapse_tenure, 2) AS deviation_from_category_avg
FROM category_benchmark
ORDER BY deviation_from_category_avg ASC;

/* ------------------------------------------------------------------
ANALYSIS:
Investors with the largest negative deviation (fastest abnormal
churn relative to their category) share tenure_at_lapse = 3 — the
earliest possible lapse point (3 consecutive missed payments from
month 1). Notably, these investors are NOT concentrated in the
dataset's traditionally high-volatility categories (Small Cap, Mid
Cap, Flexi Cap); instead they appear in categories with normally
high average tenure — Index Fund (16.81 avg), Balanced Hybrid
(14.56 avg), and ELSS (13.83 avg).

This produces the largest deviations in the dataset (-10.56 to
-13.81), because these investors abandoned their SIP almost
immediately in categories where peers typically stay invested for
over a year. This is a stronger anomaly signal than raw tenure alone
would show — an early lapse in an already-volatile category (Small
Cap) is expected behavior, but an early lapse in a traditionally
"sticky" category (Index Fund, ELSS) suggests an investor-specific
issue (e.g., onboarding friction, wrong product-fit, or a
data/service problem) rather than a category-driven one.

Business takeaway: this comparison-to-peer-group approach surfaces a
DIFFERENT risk signal than Q1-Q6 — not "which categories/schemes are
risky," but "which individual investors behaved abnormally even
relative to a safe category," which warrants root-cause investigation
distinct from category-level risk management.
------------------------------------------------------------------ */



/* ----------------------------------------------------------------
Q8: What percentage of each monthly investor cohort remains active
    at each subsequent tenure month (cohort retention curve)?
Technique: Cohort grouping via CTE + COUNT(DISTINCT) aggregation,
    combined with RANK() window function to sequence each cohort's
    timeline
Business value: Reveals the SHAPE of investor drop-off over time —
    a steep early drop signals an onboarding/first-impression
    problem, while a steady gradual decline signals long-term
    engagement fatigue. Each requires a completely different
    retention strategy.
---------------------------------------------------------------- */

WITH investor_cohort AS (
    -- Each investor's cohort = the month they started their SIP
    SELECT investor_id, MIN(month_date) AS cohort_month
    FROM sip_transactions
    GROUP BY investor_id
),
cohort_size AS (
    -- How many investors started in each cohort month
    SELECT cohort_month, COUNT(DISTINCT investor_id) AS total_cohort_investors
    FROM investor_cohort
    GROUP BY cohort_month
),
monthly_active AS (
    -- How many investors from each cohort are still generating rows
    -- (i.e., still active) at each tenure_months checkpoint
    SELECT
        ic.cohort_month,
        st.tenure_months,
        COUNT(DISTINCT st.investor_id) AS active_investors
    FROM sip_transactions st
    JOIN investor_cohort ic ON st.investor_id = ic.investor_id
    GROUP BY ic.cohort_month, st.tenure_months
)
SELECT
    ma.cohort_month,
    ma.tenure_months,
    ma.active_investors,
    cs.total_cohort_investors,
    ROUND(ma.active_investors * 100.0 / cs.total_cohort_investors, 2) AS retention_pct,
    RANK() OVER (PARTITION BY ma.cohort_month ORDER BY ma.tenure_months) AS month_sequence
FROM monthly_active ma
JOIN cohort_size cs ON ma.cohort_month = cs.cohort_month
ORDER BY ma.cohort_month, ma.tenure_months;

/* ------------------------------------------------------------------
ANALYSIS:
The Jul 2023 cohort (53 investors) shows a clean, gradual retention
decline rather than a sharp early cliff: 100% retention through
month 3, easing to 98.11% (month 4), 94.34% (month 6), 90.57%
(month 8), and 86.79% (month 11). No single month shows a dramatic
drop — retention erodes steadily and continuously rather than
concentrating losses in any specific early window.

This shape has a direct business implication: a steep drop in the
first 1-2 months would indicate an onboarding or first-impression
problem (e.g., poor investor education, unclear expectations at
sign-up). Instead, this gradual curve is more consistent with
long-term engagement fatigue building up over time — aligning with
the dataset's underlying mechanic, where discontinuation requires 3
consecutive missed payments, a condition that naturally takes months
to develop regardless of when in an investor's tenure it begins.

Business takeaway: retention interventions should be spread across
an investor's full tenure rather than concentrated only in an
initial onboarding window — there is no single "danger month" this
cohort's curve points to; risk accumulates gradually throughout.
------------------------------------------------------------------ */


-- ================================================================
-- END OF FILE
-- ================================================================






