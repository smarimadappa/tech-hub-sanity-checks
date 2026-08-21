-- D-001 sanity check — authoritative SQL. Run via the GDM Snowflake sql_exec_tool
-- (CURRENT_ACCOUNT() must be GARTNER_GDM).

-- ============================================================
-- max_dates : one row, six columns. Each should equal yesterday (IST).
-- ============================================================
SELECT
  MAX("DATE")                                                   AS overall,
  MAX(CASE WHEN BRAND = 'Capterra'         THEN "DATE" END)     AS capterra,
  MAX(CASE WHEN BRAND = 'GetApp'           THEN "DATE" END)     AS getapp,
  MAX(CASE WHEN BRAND = 'Software Advice'  THEN "DATE" END)     AS software_advice,
  MAX(CASE WHEN MONETIZATION_TYPE = 'PPC'  THEN "DATE" END)     AS ppc,
  MAX(CASE WHEN MONETIZATION_TYPE = 'PPL'  THEN "DATE" END)     AS ppl
FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE;

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
-- Source: GDM.PERFORMANCE.GDM_SES_PPC_PPL (account GARTNER_GDM, same account as the rest
-- of this check). PPL only counts qualified+accepted leads, attributed to qual date, not
-- session date or conversion date — verified against real data, don't "simplify" this.
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
WHERE DATE_UTC BETWEEN DATEADD('day', -3, :expected_max) AND DATEADD('day', 3, :expected_max);

-- ============================================================
-- revenue_reconciliation_destination (D-001) : the cube-side revenue to compare
-- against ppc_revenue + ppl_revenue above, for the same :expected_max.
-- ============================================================
SELECT SUM(REVENUE) AS destination_revenue
FROM BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE
WHERE DATE = :expected_max;
