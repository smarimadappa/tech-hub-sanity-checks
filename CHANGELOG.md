# Changelog

## d001-sanity-check
- **0.5.0** — Post-demo feedback (Laurent). Max-date checks now also assert **value > 0**:
  each slice (overall + 3 brands + PPC/PPL) must have non-zero `REVENUE` **and** `SPEND` on its
  max date, catching a fresh-but-empty slice a date-only check would pass (both PPC and PPL carry
  spend — verified). Revenue reconciliation vs. source is now **day by day over a rolling
  ~2-month window** (was last-day-only) and a matching **spend reconciliation** was added
  (`SPEND_RECONCILIATION.SOT_SPEND` vs cube `SPEND`, joined on `SOURCE` so it's like-for-like —
  verified to match to the dollar). Both stay informational-only, reported as a one-line 60-day
  summary. Also sketched (but **held pending Shubham**) a per-source spend check using the cube's
  `SOURCE` column, so a single dead engine (e.g. Bing) can't hide behind a positive total. Fixed
  a latent bug in the old source query (bare `a.` alias, doubled `;;`).
- **0.2.0** — Add informational-only revenue reconciliation vs. `GDM.PERFORMANCE.GDM_SES_PPC_PPL`
  (DMABGS-3270). Reported as a footnote in the Slack message; never gates pass/fail or pages
  on-call — source vs. destination doesn't reconcile exactly every day for reasons not yet
  understood.
- **0.1.0** — Initial release: D-001 Performance Cube daily sanity check (DMABGS-3270).

## d000-sanity-check
- **0.6.0** — Post-demo feedback (Laurent). Dropped the four unused tasks from the docs —
  `GDM_SPEND_IMPR_CLICKS_DELETE/INSERT` and `GDM_CHANNEL_DASHBOARD_V3_DELETE/INSERT` — leaving
  only `D000_CHANNEL_DASHBOARD` (the SQL already checked only that one). Added a **value > 0**
  check: a new `max_value_check` query asserts non-zero `REVENUE_ACTUALS` **and** `SPEND_ACTUALS`
  on the max date for six slices (overall + 3 brands + PPC/PPL), read straight from
  `D000_CHANNEL_DASHBOARD` (`IS_COMPLETE = 1`) so it works even before the max-date view ships;
  it gates like the date checks. Revenue reconciliation vs. source is now **day by day over a
  rolling ~2-month window** (was last-day-only; verified to match to the dollar), reported as a
  one-line 60-day summary. **Spend reconciliation is held** for D-000: it has no source/engine
  column, so `SPEND_ACTUALS` can't be scoped to `SPEND_RECONCILIATION.SOT_SPEND` cleanly (a
  `CHANNEL_ID` join is off −6% to −45%/day) — deferred pending the right key. Fixed a latent bug
  in the old source query (bare `a.` alias, doubled `;;`).
- **0.5.0** — Add shadow-mode trend/anomaly check (DMABGS-3275): flags unlikely swings in the
  newly-landed day vs. a robust same-weekday baseline (median + MAD, trailing 6, ≥4 valid), per
  `CHANNEL_GROUPED` across revenue/spend/sessions, US-holiday aware (`references/us_holidays.md`).
  Tuned against a ~9-week backtest (~4 raw flags/day → ~1 actionable/day): de-duplicates
  `SESSIONS` across `MONETIZATION_TYPE` (a 2× double-count — domain-grain metric repeated per
  type), applies per-measure absolute floors to kill small-channel noise, and classifies each
  flag as `new-break-*` vs `ongoing-*` (scores target + previous eligible day) so a channel
  mid-trend doesn't re-alarm daily. Filters on `IS_COMPLETE = 1` (the table carries forecast
  rows into the future). Informational only — never gates pass/fail or pages on-call; meant to
  run a tuning week before any case is promoted. New files: `references/anomaly.sql`,
  `references/us_holidays.md`.
- **0.2.0** — Add informational-only revenue reconciliation vs. `GDM.PERFORMANCE.GDM_SES_PPC_PPL`
  (DMABGS-3269), superseding the "deferred" note from 0.1.0. Reported as a footnote in the Slack
  message; never gates pass/fail or pages on-call — source vs. destination doesn't reconcile
  exactly every day for reasons not yet understood.
- **0.1.0** — Initial release: D-000 Channel Dashboard daily sanity check (DMABGS-3269).
  Max-date checks degrade gracefully until the companion view ships. Revenue reconciliation
  (ses_ppc_ppl vs data_product) intentionally deferred — source tables not yet specified.
