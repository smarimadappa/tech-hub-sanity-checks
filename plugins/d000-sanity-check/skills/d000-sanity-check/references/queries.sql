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
WHERE DATE_UTC BETWEEN DATEADD('day', -3, :expected_max) AND DATEADD('day', 3, :expected_max)
       AND a.is_deleted = 0
       AND a.site_property_id IN (1,2,3,4);;

-- ============================================================
-- revenue_reconciliation_destination (D-000) : the dashboard-side revenue to compare
-- against ppc_revenue + ppl_revenue above, for the same :expected_max.
-- ============================================================
SELECT SUM(REVENUE_ACTUALS) AS destination_revenue
FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD
WHERE DATE = :expected_max;
