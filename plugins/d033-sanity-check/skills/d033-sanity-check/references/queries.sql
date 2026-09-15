-- D-033 sanity check — authoritative SQL. Run via the GDM Snowflake sql_exec_tool
-- (CURRENT_ACCOUNT() must be GARTNER_GDM).
--
-- Pipeline: D-033 BX Self-Service Tool (DMABGS-3271).
-- Final table: BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST
--   (the "_ST" table is the live output — plain D033_BX_SELF_SERVICE_TOOL does not exist).
-- Date column: DATE_UTC (confirmed from schema).
-- Grain is page-level; PAGE_* and LAND_* revenue columns mirror each other, so use the
-- PAGE_* columns only for revenue totals to avoid double-counting.

-- ============================================================
-- task_states : latest non-scheduled run per task.
-- Both DELETE + INSERT tasks must be SUCCEEDED.
-- SCHEDULED_TIME is in the account timezone (UTC); the pipeline runs ~14:30 UTC
-- (07:30 America/Los_Angeles). Convert to IST when checking "today".
-- ============================================================
SELECT NAME,
       STATE,
       SCHEDULED_TIME::string AS scheduled_time,
       COMPLETED_TIME::string AS completed_time,
       ERROR_MESSAGE
FROM TABLE(BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('day', -2, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 1000))
WHERE NAME IN (
        'D033_BX_SELF_SERVICE_TOOL_DELETE_ST',
        'D033_BX_SELF_SERVICE_TOOL_INSERT_ST')
  AND STATE <> 'SCHEDULED'
QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY SCHEDULED_TIME DESC) = 1;

-- ============================================================
-- max_date : single date. Should equal yesterday (UTC) = EXPECTED_MAX.
-- ============================================================
SELECT MAX(DATE_UTC) AS max_date_utc
FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST;

-- ============================================================
-- value_check : fresh-but-empty guard. On the max date, confirm the pipeline
-- actually landed non-zero data across the dimension cuts the ticket calls out
-- (brand, monetization type). A date-only check would pass an empty refresh.
--
-- Dimensions (confirmed from real data):
--   BRAND   : Capterra, GetApp, Software Advice  (+ a tiny blank-brand bucket = noise, ignore)
--   CHANNEL : Paid, Unpaid
--   Monetization type is the PPC vs PPL revenue split.
--
-- Gate on: overall PPC revenue > 0, overall PPL revenue > 0, and every named brand
-- has combined revenue > 0 AND sessions > 0. Do NOT require PPL > 0 per brand —
-- GetApp is PPC-only (no PPL), so a per-brand PPL floor would false-fail it.
-- Replace :expected_max with EXPECTED_MAX from Step 1.
-- ============================================================
SELECT
  BRAND,
  COALESCE(SUM(PAGE_PPC_REVENUE), 0)                              AS ppc_revenue,
  COALESCE(SUM(PAGE_PPL_REVENUE), 0)                              AS ppl_revenue,
  COALESCE(SUM(PAGE_PPC_REVENUE), 0) + COALESCE(SUM(PAGE_PPL_REVENUE), 0) AS total_revenue,
  COALESCE(SUM(ALL_SESSIONS), 0)                                  AS sessions
FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST
WHERE DATE_UTC = :expected_max
  AND BRAND IN ('Capterra', 'GetApp', 'Software Advice')
GROUP BY ROLLUP (BRAND)
ORDER BY BRAND NULLS LAST;
-- The BRAND = NULL row from ROLLUP is the overall total (use it for the overall
-- PPC > 0 / PPL > 0 gate); the three named rows are the per-brand gate.

-- ============================================================
-- revenue_reconciliation (informational only — never gates pass/fail)
-- DAY BY DAY over a rolling ~2-month window ending :expected_max, PPC+PPL UNIFIED
-- into a single revenue total per day (matching D-000/D-001/D-009). A single-day
-- match can hide a mid-window break, so compare the whole window.
--
-- Source: GDM.PERFORMANCE.GDM_SES_PPC_PPL (account GARTNER_GDM).
-- Brand mapping confirmed by reconciling against the destination:
--   BRAND_ID 1 = Capterra, 2 = GetApp, 3 = Software Advice  (the three DM brands).
-- Attribution basis — verified to the dollar day-by-day against the destination
-- (2026-09-13, 61-day window: 0/61 days off >10%, totals within -0.3%):
--   PPC → click date (PPC_CLICK_TIMESTAMP_UTC), amount PPC_CLICK_AMOUNT.
--   PPL → CONVERSION date (PPL_CONV_TIMESTAMP_UTC), qualified + accepted leads only,
--         amount PPL_LEAD_AMOUNT.  NOT qual date — the D-033 destination attributes
--         PAGE_PPL_REVENUE by conversion date; qual date is materially off day-by-day
--         (it only reconciles in aggregate). Don't "simplify" back to qual date.
-- Destination: D033_BX_SELF_SERVICE_TOOL_ST PAGE_PPC_REVENUE + PAGE_PPL_REVENUE per
-- DATE_UTC. Use the PAGE_* columns (not LAND_*) to avoid double-counting.
-- Replace :expected_max with EXPECTED_MAX from Step 1. To widen toward the full
-- fiscal year later, change the -60 below.
-- ============================================================
WITH src AS (
  SELECT day, SUM(rev) AS source_revenue FROM (
    SELECT PPC_CLICK_TIMESTAMP_UTC::date AS day, PPC_CLICK_AMOUNT AS rev
      FROM GDM.PERFORMANCE.GDM_SES_PPC_PPL
     WHERE is_deleted = 0 AND BRAND_ID IN (1, 2, 3)
       AND PPC_CLICK_TIMESTAMP_UTC::date BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
    UNION ALL
    SELECT PPL_CONV_TIMESTAMP_UTC::date, PPL_LEAD_AMOUNT
      FROM GDM.PERFORMANCE.GDM_SES_PPC_PPL
     WHERE is_deleted = 0 AND BRAND_ID IN (1, 2, 3)
       AND PPL_QUAL = 1 AND PPL_LEAD_STATUS = 'accepted'
       AND PPL_CONV_TIMESTAMP_UTC::date BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
  ) GROUP BY day
), dst AS (
  SELECT DATE_UTC AS day,
         SUM(COALESCE(PAGE_PPC_REVENUE, 0) + COALESCE(PAGE_PPL_REVENUE, 0)) AS dest_revenue
    FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST
   WHERE DATE_UTC BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
   GROUP BY DATE_UTC
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
-- schema_discovery : columns of the D-033 output table.
-- Run this once if column names ever look wrong; not needed on every check.
-- ============================================================
SELECT COLUMN_NAME, DATA_TYPE
FROM BUSINESS_ANALYTICS.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'BX_ANALYTICS'
  AND TABLE_NAME = 'D033_BX_SELF_SERVICE_TOOL_ST'
ORDER BY ORDINAL_POSITION;
