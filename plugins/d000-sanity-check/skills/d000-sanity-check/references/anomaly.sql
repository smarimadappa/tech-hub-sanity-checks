-- D-000 trend/anomaly check (Step 3.5) — SHADOW MODE, informational only, NEVER gates.
-- Run via the GDM Snowflake sql_exec_tool (CURRENT_ACCOUNT() must be GARTNER_GDM).
--
-- WHAT IT RETURNS
--   One row per (channel × measure) for the latest complete actuals day, each with a
--   `status`: new-break-up / new-break-down / ongoing-up / ongoing-down / ok /
--   insufficient-baseline / holiday-suppressed. Surface the NEW-BREAK rows in the
--   Slack shadow line; list ongoing-* as a demoted footnote (a channel mid-trend
--   shouldn't re-alarm every day). Per-channel so an outlier is attributable at a
--   glance ("Partners moved"), which is how these outliers actually arise.
--
-- WHY THESE CHOICES (all verified against real GARTNER_GDM data; see the backtest notes
-- at the bottom of this file for the numbers that drove each one)
--   * Same-weekday baseline (trailing 6, require >=4 valid): weekday/weekend swings are
--     huge and channel-specific (Partners & Paid Social revenue collapse to ~0 on
--     weekends; PPL revenue ~0 and cost tiny on weekends/holidays). Mon-vs-Mondays is
--     the only honest baseline. 4 points made MAD jumpy; 6 stabilizes it.
--   * Median + MAD (robust) instead of mean/stddev — one weird past day can't poison it.
--   * SESSIONS DE-DUPLICATION (correctness fix): SESSIONS lives at the
--     (date, channel, brand, domain_group) grain and is REPEATED identically across
--     MONETIZATION_TYPE (PPC row == PPL row). Summing it naively double-counts 2x. We
--     take MAX(SESSIONS) per grain, then sum. REVENUE_ACTUALS / SPEND_ACTUALS genuinely
--     differ by monetization type and ARE additive — sum them directly. (Any other
--     session-like metric — pageviews, impressions — would need the same de-dup.)
--   * Absolute floor per measure (`floors` CTE): only evaluate a cell whose baseline
--     median clears the floor. Kills small-channel noise (AEO/Referral/Email swinging
--     +400-1100% on tiny absolute values that the percentage floor alone can't catch).
--   * US-holiday aware (references/us_holidays.md): if the target day is a US holiday or
--     weekend, every row is `holiday-suppressed` (a low day is expected). Holidays are
--     also EXCLUDED from the baseline so e.g. a Labor Day Monday can't drag later
--     Mondays' norms down. Real check: 2026-09-07 (Labor Day) naively false-flags
--     Organic Search -60%; suppression handles it.
--   * IS_COMPLETE = 1 defines the actuals boundary — the table carries FORECAST rows
--     ~2 years into the future, so never key off MAX(DATE) of the raw table.
--   * New-break vs ongoing-trend: a flat-median detector fires every day during a
--     sustained trend because the trailing baseline lags. We score the target day AND
--     the previous eligible day, and only call it a `new-break` when the previous
--     eligible day was NOT already flagged in the same direction — otherwise `ongoing`.
--     Backtest: this cut ~4 raw flags/day to ~1 actionable new-break/day.
--
-- THRESHOLD (tune during the shadow week; see notes at bottom before promoting to a gate):
--   FLAG when |robust_z| > 3.5 AND |pct deviation| > 15% AND baseline median >= floor.
--
-- The `holidays` CTE below MUST stay in sync with references/us_holidays.md.
-- ============================================================
WITH holidays AS (
  SELECT column1::date d FROM VALUES
    ('2025-01-01'),('2025-01-20'),('2025-02-17'),('2025-05-26'),('2025-06-19'),
    ('2025-07-04'),('2025-09-01'),('2025-11-11'),('2025-11-27'),('2025-12-25'),
    ('2026-01-01'),('2026-01-19'),('2026-02-16'),('2026-05-25'),('2026-06-19'),
    ('2026-07-03'),('2026-09-07'),('2026-11-11'),('2026-11-26'),('2026-12-25')
),
-- Per-measure absolute floor on the baseline median (units: $ for revenue/spend, sessions count).
floors AS (
  SELECT * FROM VALUES ('revenue',5000),('spend',5000),('sessions',5000) AS f(measure, floor_val)
),
-- SESSIONS de-duplicated to the (date, channel, brand, domain) grain (identical across
-- MONETIZATION_TYPE, so MAX == the value) before it is summed to the channel level.
grain_sess AS (
  SELECT DATE, CHANNEL_GROUPED AS ch, MAX(SESSIONS) AS gs
  FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD
  WHERE IS_COMPLETE = 1 AND CHANNEL_GROUPED <> ''
  GROUP BY DATE, CHANNEL_GROUPED, BRAND, DOMAIN_GROUP
),
-- One row per (date, channel, measure). Revenue/spend are additive; sessions comes from grain_sess.
long AS (
  SELECT DATE, CHANNEL_GROUPED AS ch, 'revenue' AS measure, SUM(REVENUE_ACTUALS) AS val
  FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD
  WHERE IS_COMPLETE = 1 AND CHANNEL_GROUPED <> '' GROUP BY 1,2
  UNION ALL
  SELECT DATE, CHANNEL_GROUPED, 'spend', SUM(SPEND_ACTUALS)
  FROM BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD
  WHERE IS_COMPLETE = 1 AND CHANNEL_GROUPED <> '' GROUP BY 1,2
  UNION ALL
  SELECT DATE, ch, 'sessions', SUM(gs) FROM grain_sess GROUP BY 1,2
),
tgt AS (SELECT MAX(DATE) AS d FROM long),   -- latest complete actuals day (may be a holiday/weekend)
-- Eligible baseline days: non-holiday weekdays, bounded lookback (baselines reach ~6 weeks back).
elig AS (
  SELECT * FROM long
  WHERE DATE NOT IN (SELECT d FROM holidays)
    AND DAYOFWEEK(DATE) NOT IN (0,6)
    AND DATE >= DATEADD('day', -120, (SELECT d FROM tgt))
),
-- Two days get scored: the target day, and the previous eligible day (for break-vs-ongoing).
cand AS (
  SELECT (SELECT d FROM tgt) AS dd
  UNION ALL
  SELECT MAX(DATE) FROM elig WHERE DATE < (SELECT d FROM tgt)
),
today2 AS (SELECT c.dd, l.ch, l.measure, l.val FROM cand c JOIN long l ON l.DATE = c.dd),
-- Each scored day joined to its 6 preceding same-weekday eligible values.
tb AS (
  SELECT t.dd, t.ch, t.measure, t.val AS tval, b.val AS bval
  FROM today2 t
  JOIN elig b ON b.ch = t.ch AND b.measure = t.measure
             AND DAYOFWEEKISO(b.DATE) = DAYOFWEEKISO(t.dd) AND b.DATE < t.dd
  QUALIFY ROW_NUMBER() OVER (PARTITION BY t.dd, t.ch, t.measure ORDER BY b.DATE DESC) <= 6
),
m   AS (SELECT dd, ch, measure, ANY_VALUE(tval) AS tval, MEDIAN(bval) AS med, COUNT(*) AS n
        FROM tb GROUP BY 1,2,3),
mad AS (SELECT tb.dd, tb.ch, tb.measure, MEDIAN(ABS(tb.bval - x.med)) AS mad
        FROM tb JOIN m x USING (dd, ch, measure) GROUP BY 1,2,3),
scored AS (
  SELECT m.dd, m.ch, m.measure, m.tval, m.med, m.n, a.mad,
    CASE WHEN m.n >= 4 AND a.mad > 0 AND m.med >= f.floor_val
          AND ABS(0.6745*(m.tval - m.med)/a.mad) > 3.5
          AND ABS(m.tval - m.med)/NULLIF(m.med,0) > 0.15
         THEN SIGN(m.tval - m.med) ELSE 0 END AS dir
  FROM m JOIN mad a USING (dd, ch, measure) JOIN floors f USING (measure)
),
tgt_row  AS (SELECT * FROM scored WHERE dd = (SELECT d FROM tgt)),
prev_row AS (SELECT ch, measure, dir AS prev_dir FROM scored
             WHERE dd = (SELECT MAX(dd) FROM scored WHERE dd < (SELECT d FROM tgt)))
SELECT
  t.dd                                     AS target_day,
  t.measure,
  t.ch                                     AS channel,
  ROUND(t.tval)                            AS today_val,
  ROUND(t.med)                             AS median_baseline,
  t.n                                      AS baseline_n,
  CASE WHEN t.mad > 0 THEN ROUND(0.6745*(t.tval - t.med)/t.mad, 1) END AS robust_z,
  CASE WHEN t.med  > 0 THEN ROUND(100*(t.tval - t.med)/t.med, 0)      END AS pct_dev,
  CASE
    WHEN (SELECT d FROM tgt) IN (SELECT d FROM holidays)
      OR DAYOFWEEK((SELECT d FROM tgt)) IN (0,6)             THEN 'holiday-suppressed'
    WHEN t.n < 4                                             THEN 'insufficient-baseline'
    WHEN t.dir = 0                                           THEN 'ok'
    WHEN t.dir = COALESCE(p.prev_dir, 0)                     THEN IFF(t.dir > 0, 'ongoing-up', 'ongoing-down')
    ELSE                                                          IFF(t.dir > 0, 'new-break-up', 'new-break-down')
  END                                      AS status
FROM tgt_row t
LEFT JOIN prev_row p USING (ch, measure)
ORDER BY t.measure, ABS(robust_z) DESC NULLS LAST;

-- ============================================================
-- Backtest context (run 2026-09, ~9 weeks of GARTNER_GDM history) — why the tuning exists:
--   * Naive version (no de-dup, no absolute floor, no break/ongoing): 179 flags over 44
--     weekdays = ~4.1/day. Unusable, and it double-counted sessions 2x.
--   * + sessions de-dup + absolute floor: 93 flags.
--   * + new-break vs ongoing: 47 NEW-breaks (46 demoted to ongoing) = ~1.0 actionable/day.
--   The surviving new-breaks read as real story beats (Paid Search dip late Jul; Partners
--   revenue up then reversing; Paid Display/Social sustained decline; Direct sessions
--   stair-stepping up). See the skill Notes for the standing data caveats (sessions
--   duplication; the localized Direct/TLD-Capterra/GetApp sessions surge).
--
-- Tuning knobs for after the shadow week:
--   * To split PPC vs PPL (MONETIZATION_TYPE — where the PPL/weekend effect is strongest),
--     add it to the GROUP BY / PARTITION BY and SELECT. Left channel-level for the first pass.
--     NOTE: if you add MONETIZATION_TYPE, the sessions de-dup above is already correct (grain
--     includes brand/domain, not monetization) — but you'd then be attributing one domain's
--     sessions to two monetization rows, so keep sessions channel-level or divide out.
--   * If a healthy day still over-flags, widen the baseline (`<= 6` -> `<= 8`), raise z (3.5),
--     the pct floor (0.15), or the absolute floors above.
--   * The blank channel ('') is excluded — negligible volume.
-- ============================================================
