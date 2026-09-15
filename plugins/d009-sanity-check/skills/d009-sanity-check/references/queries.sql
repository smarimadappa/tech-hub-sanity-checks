-- D-009 sanity check — authoritative SQL. Run via the GDM Snowflake sql_exec_tool
-- (CURRENT_ACCOUNT() must be GARTNER_GDM).

-- ============================================================
-- task_states : latest non-scheduled run per task.
-- Parent + all 5 children must be SUCCEEDED.
-- SCHEDULED_TIME is in the account timezone (UTC); convert to IST when checking "today".
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
        'D009_SITE_PERF_PV_PARENT',
        'D009_SITE_PERF_PPC_CHILD',
        'D009_SITE_PERF_PPL_CHILD',
        'D009_SITE_PERF_CHAT_CHILD',
        'D009_SITE_PERF_FORMS_CHILD',
        'D009_SITE_PERF_PV_CHILD')
  AND STATE <> 'SCHEDULED'
QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY SCHEDULED_TIME DESC) = 1;

-- ============================================================
-- max_dates : one row, five columns. Each should equal yesterday (UTC).
-- NOTE: PPL and FORMS use DATE (not DATE_UTC) — confirmed from real schema.
-- CHAT and PV are assumed DATE_UTC; correct if needed.
-- ============================================================
SELECT
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPC)   AS ppc,
  (SELECT MAX(DATE)     FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPL)   AS ppl,
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_CHAT)  AS chat,
  (SELECT MAX(DATE)     FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_FORMS) AS forms,
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PV)    AS pv;

-- ============================================================
-- revenue_reconciliation (informational only — never gates pass/fail)
-- DAY BY DAY over a rolling ~2-month window ending :expected_max, PPC+PPL UNIFIED
-- into a single revenue total per day (matching D-000/D-001/D-033). A single-day
-- match can hide a mid-window break, so compare the whole window.
--
-- Source: GDM.PERFORMANCE.GDM_SES_PPC_PPL (account GARTNER_GDM), site_property_id 1-4.
-- Attribution basis — verified to the dollar day-by-day against the destination on
-- every day the destination carries data:
--   PPC → click date (PPC_CLICK_TIMESTAMP_UTC), amount PPC_CLICK_AMOUNT.
--   PPL → QUAL date (PPL_QUAL_TIMESTAMP_UTC), qualified + accepted leads only,
--         amount PPL_LEAD_AMOUNT.  (D-009's PPL destination attributes REVENUE by
--         qual date — conversion date is off here, the opposite of D-033. Don't swap.)
-- Destination tables (column names differ, confirmed from schema):
--   D009_SITE_PERF_PPC → date DATE_UTC; PPC revenue is PPC_CLICK_AMOUNT (NOT
--     REVENUE_WO_SESSION — that column is a partial subset and does not reconcile).
--   D009_SITE_PERF_PPL → date DATE (not DATE_UTC); PPL revenue is REVENUE.
-- Verified: PPC reconciles 0/61 days off; PPL reconciles to the dollar on every day
-- the destination has data. NOTE the D009_SITE_PERF_PPL table can lag the PPC table
-- by weeks — when it does, this recon will flag the missing PPL days. That is a real
-- freshness gap, already gated by the max_dates check (Step 3); here it is only a note.
-- Replace :expected_max with EXPECTED_MAX from Step 1. To widen the window, change -60.
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
  SELECT day, SUM(rev) AS dest_revenue FROM (
    SELECT DATE_UTC AS day, PPC_CLICK_AMOUNT AS rev
      FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPC
     WHERE DATE_UTC BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
    UNION ALL
    SELECT "DATE" AS day, REVENUE AS rev
      FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPL
     WHERE "DATE" BETWEEN DATEADD('day', -60, :expected_max) AND :expected_max
  ) GROUP BY day
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
-- schema_discovery : revenue/amount columns in all D009 output tables.
-- Run this once if destination column names are uncertain; not needed on every check.
-- ============================================================
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM BUSINESS_ANALYTICS.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'BX_ANALYTICS'
  AND TABLE_NAME IN (
        'D009_SITE_PERF_PPC',
        'D009_SITE_PERF_PPL',
        'D009_SITE_PERF_CHAT',
        'D009_SITE_PERF_FORMS',
        'D009_SITE_PERF_PV')
  AND (COLUMN_NAME ILIKE '%REVENUE%' OR COLUMN_NAME ILIKE '%AMOUNT%')
ORDER BY TABLE_NAME, COLUMN_NAME;
