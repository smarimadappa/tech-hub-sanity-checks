-- D-000 sanity check — authoritative SQL. Run via the GDM Snowflake sql_exec_tool
-- (CURRENT_ACCOUNT() must be GARTNER_GDM).

-- ============================================================
-- task_states : latest non-scheduled run for the dashboard task. Must be SUCCEEDED.
-- Only D000_CHANNEL_DASHBOARD is monitored now — the old GDM_SPEND_IMPR_CLICKS_* and
-- GDM_CHANNEL_DASHBOARD_V3_* tasks are no longer used (Laurent, post-demo) and were dropped.
-- SCHEDULED_TIME is UTC (the account timezone) — no conversion needed, the
-- D-000 pipeline is anchored on UTC calendar days.
-- ============================================================
SELECT NAME, STATE, SCHEDULED_TIME::string AS scheduled_time,
       COMPLETED_TIME::string AS completed_time, ERROR_MESSAGE
FROM TABLE(BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 1000))
WHERE NAME IN ('D000_CHANNEL_DASHBOARD')
  AND STATE <> 'SCHEDULED'
QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY SCHEDULED_TIME DESC) = 1;

-- ============================================================
-- max_dates : one row, seven columns. Each should equal yesterday (UTC).
-- Only query this once Step 3's INFORMATION_SCHEMA.COLUMNS check confirms the
-- view exists — it's still being rolled out via a companion ticket.
-- ============================================================
SELECT MAX_DATE_SPEND, MAX_DATE_SITE, max_date_spend_capterra, max_date_spend_getapp,
       max_date_spend_software_advice, max_date_spend_ppc, max_date_spend_ppl
FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD_MAX_DATES;

-- ============================================================
-- max_value_check : freshness is not enough — a slice can land a fresh date with
-- all-zero revenue/spend (a silent partial failure). This asserts value > 0 on each
-- slice's max date (Laurent, post-demo). Runs directly on D000_CHANNEL_DASHBOARD, so
-- it works even before the max_dates view above ships. IS_COMPLETE = 1 excludes the
-- forecast rows the table carries ~2 years into the future.
-- Each slice: max_date must = EXPECTED_MAX, and rev_on_max / spend_on_max must be > 0.
-- ============================================================
WITH slices AS (
  SELECT 'overall'         AS slice, "DATE" AS d, REVENUE_ACTUALS AS r, SPEND_ACTUALS AS s FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD WHERE IS_COMPLETE = 1
  UNION ALL SELECT 'Capterra',        "DATE", REVENUE_ACTUALS, SPEND_ACTUALS FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD WHERE IS_COMPLETE = 1 AND BRAND = 'Capterra'
  UNION ALL SELECT 'GetApp',          "DATE", REVENUE_ACTUALS, SPEND_ACTUALS FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD WHERE IS_COMPLETE = 1 AND BRAND = 'GetApp'
  UNION ALL SELECT 'Software Advice', "DATE", REVENUE_ACTUALS, SPEND_ACTUALS FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD WHERE IS_COMPLETE = 1 AND BRAND = 'Software Advice'
  UNION ALL SELECT 'PPC',             "DATE", REVENUE_ACTUALS, SPEND_ACTUALS FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD WHERE IS_COMPLETE = 1 AND MONETIZATION_TYPE = 'PPC'
  UNION ALL SELECT 'PPL',             "DATE", REVENUE_ACTUALS, SPEND_ACTUALS FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD WHERE IS_COMPLETE = 1 AND MONETIZATION_TYPE = 'PPL'
), ranked AS (
  SELECT slice, d, r, s, MAX(d) OVER (PARTITION BY slice) AS mx FROM slices
)
SELECT slice,
       mx                                        AS max_date,
       ROUND(SUM(CASE WHEN d = mx THEN r END))   AS rev_on_max,
       ROUND(SUM(CASE WHEN d = mx THEN s END))   AS spend_on_max
FROM ranked
GROUP BY slice, mx
ORDER BY slice;

-- ============================================================
-- revenue_reconciliation (informational only — never gates pass/fail)
-- DAY BY DAY over a rolling ~2-month window ending :expected_max (Laurent, post-demo:
-- do the source check over the whole window, not just the last day). Source:
-- GDM.PERFORMANCE.GDM_SES_PPC_PPL. PPL only counts qualified+accepted leads, attributed
-- to qual date (not session/conversion date) — verified against real data, don't
-- "simplify" this. Destination: D000_CHANNEL_DASHBOARD REVENUE_ACTUALS (IS_COMPLETE = 1).
-- Verified: matches to the dollar across the tested window. Replace :expected_max with
-- EXPECTED_MAX from Step 1. To widen toward the full fiscal year, change -60 below.
-- ============================================================
WITH src AS (
  SELECT day, SUM(rev) AS source_revenue FROM (
    SELECT PPC_CLICK_TIMESTAMP_UTC::date AS day, PPC_CLICK_AMOUNT AS rev
      FROM GDM.PERFORMANCE.GDM_SES_PPC_PPL
     WHERE is_deleted = 0 AND site_property_id IN (1,2,3,4)
       AND PPC_CLICK_TIMESTAMP_UTC::date BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
    UNION ALL
    SELECT PPL_QUAL_TIMESTAMP_UTC::date, PPL_LEAD_AMOUNT
      FROM GDM.PERFORMANCE.GDM_SES_PPC_PPL
     WHERE is_deleted = 0 AND site_property_id IN (1,2,3,4)
       AND PPL_QUAL = 1 AND PPL_LEAD_STATUS = 'accepted'
       AND PPL_QUAL_TIMESTAMP_UTC::date BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
  ) GROUP BY day
), dst AS (
  SELECT "DATE" AS day, SUM(REVENUE_ACTUALS) AS dest_revenue
    FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD
   WHERE IS_COMPLETE = 1
     AND "DATE" BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
   GROUP BY "DATE"
)
SELECT COALESCE(src.day, dst.day)                                   AS day,
       ROUND(src.source_revenue)                                    AS source_revenue,
       ROUND(dst.dest_revenue)                                      AS dest_revenue,
       ROUND(dst.dest_revenue - src.source_revenue)                 AS diff,
       ROUND(100 * (dst.dest_revenue - src.source_revenue)
             / NULLIF(src.source_revenue, 0), 1)                    AS pct
FROM src FULL OUTER JOIN dst ON src.day = dst.day
ORDER BY day;

-- ============================================================
-- spend_reconciliation (informational only — never gates pass/fail)
-- Laurent, post-demo: "same but for spend." DAY BY DAY over the same rolling ~2-month window.
-- Source spend table: GDM.MARKETING.SPEND_REPORTING (AMOUNT_SPENT) — the granular source of
-- truth, per date × source × channel × brand × campaign, carrying EVERY engine including
-- Partner. Destination: D000_CHANNEL_DASHBOARD SPEND_ACTUALS (IS_COMPLETE = 1). Compared on the
-- FULL DAILY TOTAL — no source/channel scoping needed: the daily totals match to the dollar
-- (verified 0/61 days off across the tested window).
--
-- This UNBLOCKS the check that was previously held: the old attempt joined SPEND_REPORTING's
-- predecessor (GDM.PERFORMANCE.SPEND_RECONCILIATION) on CHANNEL_ID, which reconciled poorly
-- (off -6% to -45% day by day) because D-000's SPEND_ACTUALS uses a different channel taxonomy
-- and the SOT lacked Partner/Other. Comparing full daily totals against SPEND_REPORTING sidesteps
-- the taxonomy mismatch entirely. D000_CHANNEL_DASHBOARD still has no source/engine column, so a
-- per-source spend breakdown here is not possible — that stays in D-001, which carries SOURCE.
-- Replace :expected_max with EXPECTED_MAX from Step 1. To widen the window, change -60 below.
-- ============================================================
WITH src AS (
  SELECT "DATE"::date AS day, SUM(AMOUNT_SPENT) AS source_spend
    FROM GDM.MARKETING.SPEND_REPORTING
   WHERE "DATE"::date BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
   GROUP BY 1
), dst AS (
  SELECT "DATE" AS day, SUM(SPEND_ACTUALS) AS dest_spend
    FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD
   WHERE IS_COMPLETE = 1
     AND "DATE" BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
   GROUP BY "DATE"
)
SELECT COALESCE(src.day, dst.day)                                   AS day,
       ROUND(src.source_spend)                                      AS source_spend,
       ROUND(dst.dest_spend)                                        AS dest_spend,
       ROUND(dst.dest_spend - src.source_spend)                     AS diff,
       ROUND(100 * (dst.dest_spend - src.source_spend)
             / NULLIF(src.source_spend, 0), 1)                      AS pct
FROM src FULL OUTER JOIN dst ON src.day = dst.day
ORDER BY day;
-- (The value>0 spend check in max_value_check above is unaffected — that reads D-000's own
-- SPEND_ACTUALS and needs no source join.)
