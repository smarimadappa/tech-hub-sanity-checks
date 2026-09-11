-- D-001 sanity check — authoritative SQL. Run via the GDM Snowflake sql_exec_tool
-- (CURRENT_ACCOUNT() must be GARTNER_GDM).

-- ============================================================
-- max_dates : one row per slice, four columns. Each slice's MAX_DATE must equal
-- yesterday (IST) AND its REV_ON_MAX / SPEND_ON_MAX must both be > 0. A fresh date
-- with all-zero revenue/spend is a silent failure a date-only check would miss, so
-- we assert value > 0 on the max date too (Laurent, post-demo feedback).
-- Slices: overall, the three brands (Capterra / GetApp / Software Advice), and the
-- two monetization types (PPC / PPL). Both PPC and PPL genuinely carry spend — verified.
-- ============================================================
WITH slices AS (
  SELECT 'overall'         AS slice, "DATE" AS d, REVENUE, SPEND FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE
  UNION ALL SELECT 'Capterra',        "DATE", REVENUE, SPEND FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE WHERE BRAND = 'Capterra'
  UNION ALL SELECT 'GetApp',          "DATE", REVENUE, SPEND FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE WHERE BRAND = 'GetApp'
  UNION ALL SELECT 'Software Advice', "DATE", REVENUE, SPEND FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE WHERE BRAND = 'Software Advice'
  UNION ALL SELECT 'PPC',             "DATE", REVENUE, SPEND FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE WHERE MONETIZATION_TYPE = 'PPC'
  UNION ALL SELECT 'PPL',             "DATE", REVENUE, SPEND FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE WHERE MONETIZATION_TYPE = 'PPL'
), ranked AS (
  SELECT slice, d, REVENUE, SPEND, MAX(d) OVER (PARTITION BY slice) AS mx FROM slices
)
SELECT slice,
       mx                                              AS max_date,
       ROUND(SUM(CASE WHEN d = mx THEN REVENUE END))   AS rev_on_max,
       ROUND(SUM(CASE WHEN d = mx THEN SPEND   END))   AS spend_on_max
FROM ranked
GROUP BY slice, mx
ORDER BY slice;

-- ============================================================
-- task_states : latest non-scheduled run per task. Both are daily tasks and each
-- must be SUCCEEDED with its latest run dated today (IST).
-- SCHEDULED_TIME is in the account timezone; convert to IST when checking "today".
-- ============================================================
SELECT NAME,
       STATE,
       SCHEDULED_TIME::string AS scheduled_time,
       COMPLETED_TIME::string AS completed_time,
       ERROR_MESSAGE
FROM TABLE(BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 1000))
WHERE NAME IN (
        'D001_PERFORMANCE_CUBE_REFRESH',
        'MDD_CAMPAIGN_REFERENCE_INSERT')
  AND STATE <> 'SCHEDULED'
QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY SCHEDULED_TIME DESC) = 1;

-- ============================================================
-- revenue_reconciliation (informational only — never gates pass/fail)
-- DAY BY DAY over a rolling ~2-month window ending :expected_max (Laurent wanted the
-- full window, not just the last day — a single-day match can hide a mid-window break).
-- Source: GDM.PERFORMANCE.GDM_SES_PPC_PPL (account GARTNER_GDM). PPL only counts
-- qualified+accepted leads, attributed to qual date (not session/conversion date) —
-- verified against real data, don't "simplify" this. Destination: cube REVENUE per DATE.
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
  SELECT "DATE" AS day, SUM(REVENUE) AS dest_revenue
    FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE
   WHERE "DATE" BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
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
-- DAY BY DAY over the same rolling ~2-month window (Laurent, post-demo: "same but for spend").
-- Source spend table: GDM.MARKETING.SPEND_REPORTING (AMOUNT_SPENT) — the granular source of
-- truth, per date × source × channel × brand × campaign, carrying EVERY engine including
-- Partner. Destination: cube SPEND. Compared on the FULL DAILY TOTAL — no source-scoping
-- needed: SPEND_REPORTING's daily total equals the cube's SPEND to the dollar (verified
-- 0/61 days off across the tested window). This replaces the old
-- GDM.PERFORMANCE.SPEND_RECONCILIATION.SOT_SPEND join, which only tracked the paid-media
-- engines (Google/Bing/Facebook/LinkedIn/Quora) and so needed a per-source join to match;
-- SPEND_REPORTING matches unscoped because it includes Partner/Other too.
-- Replace :expected_max with EXPECTED_MAX from Step 1.
-- ============================================================
WITH src AS (
  SELECT "DATE"::date AS day, SUM(AMOUNT_SPENT) AS source_spend
    FROM GDM.MARKETING.SPEND_REPORTING
   WHERE "DATE"::date BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
   GROUP BY 1
), dst AS (
  SELECT "DATE" AS day, SUM(SPEND) AS dest_spend
    FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE
   WHERE "DATE" BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
   GROUP BY 1
)
SELECT src.day                                                      AS day,
       ROUND(src.source_spend)                                      AS source_spend,
       ROUND(dst.dest_spend)                                        AS dest_spend,
       ROUND(dst.dest_spend - src.source_spend)                     AS diff,
       ROUND(100 * (dst.dest_spend - src.source_spend)
             / NULLIF(src.source_spend, 0), 1)                      AS pct
FROM src LEFT JOIN dst ON src.day = dst.day
ORDER BY src.day;

-- ============================================================
-- spend_by_source (POINT 3 — HELD pending confirmation with Shubham; do NOT wire in yet)
-- Laurent, post-demo: a bare "spend > 0" won't catch one engine dying while another is
-- healthy (e.g. Bing fails but Google keeps total spend > 0). The cube HAS the source
-- dimension to catch this — SOURCE column, values include: Google, Bing, Facebook,
-- LinkedIn, Partner, Other, Quora, Reddit, DV360, AI. Intended shape below: per-source
-- spend on the max date, so a dead engine surfaces as spend = 0 for that source while
-- others are fine. Held because (a) Laurent wanted to sanity-check the design with Shubham
-- and (b) we still need to agree which sources are "must-be-nonzero daily" vs intermittent
-- (Quora/Reddit/DV360 are sparse and would false-alarm). Once agreed, promote this to a
-- real check. Reference query:
--   SELECT SOURCE,
--          MAX("DATE") AS max_date,
--          ROUND(SUM(CASE WHEN "DATE" = :expected_max THEN SPEND END)) AS spend_on_max
--   FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE
--   WHERE SOURCE IN ('Google','Bing','Facebook','LinkedIn')   -- the always-on engines, TBC with Shubham
--   GROUP BY SOURCE ORDER BY SOURCE;
