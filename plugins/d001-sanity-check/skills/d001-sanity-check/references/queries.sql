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
