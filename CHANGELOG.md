# Changelog

## d033-sanity-check
- **0.1.1** — Documented why D-033 has **no spend reconciliation**: it's a self-service
  page-performance pipeline (sessions + PPC/PPL revenue per page) with no media-spend column on the
  destination side, so there's nothing to reconcile spend against (ad spend lives only in D-000 /
  D-001). Note added to Step 4. No behavior change.
- **0.1.0** — Initial release: D-033 BX Self-Service Tool daily sanity check (DMABGS-3271).
  Verifies the two Snowflake tasks (`D033_BX_SELF_SERVICE_TOOL_DELETE_ST` +
  `..._INSERT_ST`) succeeded and the output table
  `BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST` is fresh
  (`MAX(DATE_UTC)` = yesterday UTC). Adds a value > 0 guard on the max date: overall
  PPC and PPL revenue > 0, plus each brand (Capterra, GetApp, Software Advice) with
  combined revenue and sessions > 0 (GetApp is PPC-only, so no per-brand PPL floor).
  Revenue reconciliation vs. `GDM.PERFORMANCE.GDM_SES_PPC_PPL` (brand_id 1/2/3 =
  Capterra/GetApp/Software Advice) is reported PPC and PPL separately, informational
  only — PPC ties to ~0.06%, PPL diverges by attribution and never gates. Same Slack
  channel + on-call rotation as d000/d001/d009.

## d001-sanity-check
- **0.7.0** — Promoted the previously-held per-source spend check to a **real gating check**
  (Step 4.5), scoped to the two always-on paid-search engines: **Google and Bing must each have
  `SPEND` > 0 on `EXPECTED_MAX`**. Catches one engine dying (e.g. Bing → 0) while another keeps
  the overall total positive — a case the slice-level spend > 0 checks miss. A zero/null for
  either now flips the header to `FAILURES DETECTED` and pages on-call, and the per-source line is
  shown in the Slack summary. Other sources (Facebook/LinkedIn/Partner/Quora/Reddit/DV360) stay
  out for now — several are intermittent and would false-alarm; widen only after confirming with
  Shubham. Wires in the `spend_by_source` query that 0.5.0 sketched.
- **0.6.0** — Switched the spend reconciliation source to **`GDM.MARKETING.SPEND_REPORTING`**
  (`AMOUNT_SPENT`), replacing the old `GDM.PERFORMANCE.SPEND_RECONCILIATION.SOT_SPEND` per-source
  join. `SPEND_REPORTING` is the granular source of truth (per date × source × channel × brand ×
  campaign) and carries every engine including Partner, so its **full daily total** equals the
  cube's `SPEND` to the dollar with no source-scoping — verified 0/61 days off across the window.
  Simpler and more complete than the old scoped join (which needed per-source alignment and still
  couldn't match unscoped totals). Still informational-only, one-line 60-day summary.
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
- **0.7.0** — **Unblocked the held spend reconciliation** (Laurent's "same but for spend"). It was
  held because D-000 has no source/engine column and a `CHANNEL_ID` join against the old SOT
  reconciled poorly (−6% to −45%). New approach: compare `SPEND_ACTUALS` against source spend table
  **`GDM.MARKETING.SPEND_REPORTING`** (`AMOUNT_SPENT`) on the **full daily total** — no taxonomy
  join needed. Verified 0/61 days off across the window. Reported day-by-day as a one-line 60-day
  summary alongside the revenue recon, informational-only, never gates. A per-source spend
  breakdown stays out of D-000 (no source column) — that remains D-001's job.
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

## d009-sanity-check
- **0.1.5** — Documented why D-009 has **no spend reconciliation**: it's a site-performance
  pipeline (sessions, pageviews, forms, chats + PPC/PPL revenue) with no media-spend column on the
  destination side (`BUDGET_SELECTED` in the FORMS table is a lead's self-reported budget range,
  not ad spend), so there's nothing to reconcile spend against — ad spend lives only in D-000 /
  D-001. Note added to Step 4. No behavior change.
