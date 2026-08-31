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
-- DATE_UTC is the date column in all five output tables.
-- ============================================================
SELECT
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPC)   AS ppc,
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPL)   AS ppl,
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_CHAT)  AS chat,
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_FORMS) AS forms,
  (SELECT MAX(DATE_UTC) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PV)    AS pv;

-- ============================================================
-- revenue_reconciliation (informational only — never gates pass/fail)
-- Source: GDM.PERFORMANCE.GDM_SES_PPC_PPL (account GARTNER_GDM).
-- PPL only counts qualified+accepted leads, attributed to qual date — don't simplify.
-- Replace :expected_max with EXPECTED_MAX from Step 1.
-- ============================================================
SELECT
  SUM(CASE WHEN PPC_CLICK_TIMESTAMP_UTC::date = :expected_max THEN PPC_CLICK_AMOUNT END)
    AS ppc_revenue,
  SUM(CASE WHEN PPL_QUAL_TIMESTAMP_UTC::date = :expected_max
             AND PPL_QUAL = 1 AND PPL_LEAD_STATUS = 'accepted'
           THEN PPL_LEAD_AMOUNT END)
    AS ppl_revenue
FROM GDM.PERFORMANCE.GDM_SES_PPC_PPL
WHERE DATE_UTC BETWEEN DATEADD('day', -3, :expected_max) AND DATEADD('day', 3, :expected_max)
  AND is_deleted = 0
  AND site_property_id IN (1,2,3,4);

-- ============================================================
-- revenue_reconciliation_destination (D-009) : sum PPC + PPL revenue from the
-- destination tables for the same :expected_max, to compare against source above.
-- Verify REVENUE is the correct column name when first running against real data.
-- ============================================================
SELECT
  COALESCE((SELECT SUM(REVENUE) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPC
             WHERE DATE_UTC = :expected_max), 0) +
  COALESCE((SELECT SUM(REVENUE) FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPL
             WHERE DATE_UTC = :expected_max), 0)
  AS destination_revenue;
