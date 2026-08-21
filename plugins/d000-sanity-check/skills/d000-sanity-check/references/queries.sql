-- D-000 sanity check — authoritative SQL. Run via the GDM Snowflake sql_exec_tool
-- (CURRENT_ACCOUNT() must be GARTNER_GDM).

-- ============================================================
-- task_states : latest non-scheduled run per task. All five must be SUCCEEDED.
-- SCHEDULED_TIME is UTC (the account timezone) — no conversion needed, the
-- D-000 pipeline is anchored on UTC calendar days.
-- ============================================================
SELECT NAME, STATE, SCHEDULED_TIME::string AS scheduled_time,
       COMPLETED_TIME::string AS completed_time, ERROR_MESSAGE
FROM TABLE(BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 1000))
WHERE NAME IN (
        'GDM_SPEND_IMPR_CLICKS_DELETE', 'GDM_SPEND_IMPR_CLICKS_INSERT',
        'GDM_CHANNEL_DASHBOARD_V3_DELETE', 'GDM_CHANNEL_DASHBOARD_V3_INSERT',
        'D000_CHANNEL_DASHBOARD')
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
