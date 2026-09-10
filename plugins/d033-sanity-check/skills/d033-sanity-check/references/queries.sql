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
-- revenue_reconciliation_destination (informational only — never gates pass/fail)
-- D-033 destination revenue on EXPECTED_MAX, PPC and PPL reported separately.
-- Replace :expected_max with EXPECTED_MAX from Step 1.
-- ============================================================
SELECT
  COALESCE(SUM(PAGE_PPC_REVENUE), 0) AS dest_ppc,
  COALESCE(SUM(PAGE_PPL_REVENUE), 0) AS dest_ppl
FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST
WHERE DATE_UTC = :expected_max;

-- ============================================================
-- revenue_reconciliation_source (informational only — never gates pass/fail)
-- Source: GDM.PERFORMANCE.GDM_SES_PPC_PPL (account GARTNER_GDM).
-- Brand mapping confirmed by reconciling against the destination:
--   BRAND_ID 1 = Capterra, 2 = GetApp, 3 = Software Advice  (the three DM brands).
-- PPC is attributed to click date; PPL only counts qualified + accepted leads,
-- attributed to qual date — don't simplify. Widen DATE_UTC to catch rows whose
-- click/qual date sits near the boundary.
-- Replace :expected_max with EXPECTED_MAX from Step 1.
--
-- Reconciliation reality (verified 2026-09-08): PPC matches the destination almost
-- exactly (~0.06%); PPL by qual date runs materially higher than the destination
-- PPL (attribution basis differs). Report both as notes, never as a gate.
-- ============================================================
SELECT
  SUM(CASE WHEN PPC_CLICK_TIMESTAMP_UTC::date = :expected_max
           THEN PPC_CLICK_AMOUNT END)                                   AS src_ppc,
  SUM(CASE WHEN PPL_QUAL_TIMESTAMP_UTC::date = :expected_max
             AND PPL_QUAL = 1 AND PPL_LEAD_STATUS = 'accepted'
           THEN PPL_LEAD_AMOUNT END)                                    AS src_ppl
FROM GDM.PERFORMANCE.GDM_SES_PPC_PPL
WHERE DATE_UTC BETWEEN DATEADD('day', -3, :expected_max) AND DATEADD('day', 3, :expected_max)
  AND IS_DELETED = 0
  AND BRAND_ID IN (1, 2, 3);

-- ============================================================
-- schema_discovery : columns of the D-033 output table.
-- Run this once if column names ever look wrong; not needed on every check.
-- ============================================================
SELECT COLUMN_NAME, DATA_TYPE
FROM BUSINESS_ANALYTICS.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'BX_ANALYTICS'
  AND TABLE_NAME = 'D033_BX_SELF_SERVICE_TOOL_ST'
ORDER BY ORDINAL_POSITION;
