---
name: d000-sanity-check
description: >-
  Run the daily D-000 Channel Dashboard data-pipeline sanity check (Jira DMABGS-3269) and post
  a pass/fail summary to Slack. Use this skill WHENEVER the user asks to run or trigger the
  "D-000 sanity check", "sanity check the channel dashboard", check whether the
  D000_CHANNEL_DASHBOARD Snowflake task ran, confirm the D-000 max
  dates are current, or when a scheduled task invokes the daily D-000 check — even if phrased
  loosely (e.g. "is the channel dashboard fresh?", "did spend/impressions/clicks load today?",
  "check the D-000 pipeline"). It checks the GDM Snowflake + Slack connectors and live compute
  first, verifies the D-000 Snowflake task succeeded, checks that each dashboard slice is fresh
  with non-zero revenue and spend, checks the
  D000_CHANNEL_DASHBOARD_MAX_DATES view (degrading gracefully if that view isn't deployed yet),
  runs an hourly-completeness gate (all 24 UTC hours of PPC clicks and sessions present on the
  checked day, to catch feed interruptions / site downtime / partial-day loads),
  then posts the result (tagging the week's on-call) to #sanity-check-testing. Also runs a
  shadow-mode trend/anomaly check that flags unlikely day-over-day swings in the new data
  versus recent same-weekday norms (per channel, US-holiday aware) — informational only, never
  gates. Prefer this skill over ad-hoc SQL whenever D-000 / channel dashboard monitoring is
  involved.
---

# D-000 Channel Dashboard — daily sanity check

Monitors the D-000 (Channel Dashboard) data pipeline for the GDM analytics team and reports
to Slack. It confirms the pipeline's Snowflake tasks all succeeded, and confirms the dashboard's
data is fresh (max date = yesterday UTC) overall and across each spend source. Jira reference:
**DMABGS-3269** (parent epic **DMABGS-3274**).

This is the sibling check to `d001-sanity-check` (D-001 Performance Cube) — same pattern, same
Slack channel, same on-call rotation. Post the result even on success so the team can trust
"no news" isn't just a silent failure.

## Environment facts (do not re-derive)

- **Snowflake:** GDM account, `CURRENT_ACCOUNT()` = `GARTNER_GDM`. Task history lives in
  `BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY`; the max-date view (once deployed) lives
  in `BUSINESS_ANALYTICS.ANALYTICS_MART.D000_CHANNEL_DASHBOARD_MAX_DATES`. Use the connected
  Snowflake SQL tool (`sql_exec_tool`).
- **Slack destination:** `#sanity-check-testing`, channel_id `C0BN4GXJE10` — same channel as
  D-001. Post with the Slack `slack_send_message` tool.
- **Pipeline timing (UTC):** spend task ~13:15–13:20, channel-dashboard task ~13:45–13:50,
  PowerBI refresh ~14:00–14:05. Run the check after ~14:15 UTC so all tasks and the day's data
  are present.
- **"Today" / "yesterday"** mean the UTC calendar day. This is a flagged assumption — the ticket
  doesn't say explicitly, unlike D-001 which is anchored on IST.
- **Revenue and spend reconciliations are informational only, not a gate:** verified against real
  data in `GARTNER_GDM`. Spend uses source `GDM.MARKETING.SPEND_REPORTING` (`AMOUNT_SPENT`) vs.
  `SPEND_ACTUALS` on the full daily total (0/61 days off). Revenue uses source
  `GDM.PERFORMANCE.GDM_SES_PPC_PPL` — the source vs. destination formula matches
  exactly on most days but not every day, for reasons not yet understood (checked
  `GDM_CHANNEL_DASHBOARD_CORRECTION_DATA` — no rows for the mismatching date, so that's not it).
  Because of that unexplained variance, it must never gate pass/fail or page on-call — see Step 4.
- **Max-date view rollout:** `D000_CHANNEL_DASHBOARD_MAX_DATES` is being rolled out via a
  companion ticket and may not exist yet. A missing view is never a data failure — see Step 3.
- **Keep in sync:** the on-call rotation table in `references/rotation.md` must stay identical
  to `d001-sanity-check`'s copy (same team, same channel). They are independent files with no
  automatic sharing — update both by hand.

## The Snowflake task

- `D000_CHANNEL_DASHBOARD` (`BUSINESS_ANALYTICS.ANALYTICS_MART`) — calls `SP_CHANNEL_DASHBOARD()`

Its latest non-`SCHEDULED` run must be `SUCCEEDED`. The old `GDM_SPEND_IMPR_CLICKS_DELETE` /
`GDM_SPEND_IMPR_CLICKS_INSERT` / `GDM_CHANNEL_DASHBOARD_V3_DELETE` /
`GDM_CHANNEL_DASHBOARD_V3_INSERT` tasks (CHANNEL_ANALYTICS) are **no longer used** and are not
monitored — dropped per Laurent's post-demo feedback.

## The seven max-date checks (freshness) + value>0

Once the view exists, each of these must equal yesterday (UTC): `MAX_DATE_SPEND`,
`MAX_DATE_SITE`, `max_date_spend_capterra`, `max_date_spend_getapp`,
`max_date_spend_software_advice`, `max_date_spend_ppc`, `max_date_spend_ppl`.

Freshness alone isn't enough — a slice can land a fresh date with all-zero revenue/spend
(a silent partial failure). So a separate `max_value_check` query (see Step 3.1) asserts
non-zero `REVENUE_ACTUALS` **and** `SPEND_ACTUALS` on the max date for each of six slices
(overall + 3 brands + PPC + PPL), reading `D000_CHANNEL_DASHBOARD` directly (so it works even
before the max-date view ships). This is Laurent's post-demo ask.

## Run the check in this order

### Step 0 — Connector precheck (do this first, always)

You cannot report anything without Slack, and you cannot check anything without Snowflake,
so verify both before doing real work. This makes failures explicit instead of silent.

1. **Slack.** Confirm the Slack tool is available (e.g. a lightweight `slack_search_users`
   or channel lookup). If Slack is unreachable, you have nowhere to post — stop and clearly
   state in your run output that the Slack connector is down and the check could not report.
2. **Snowflake connector (GDM).** Run `SELECT CURRENT_ACCOUNT();` via `sql_exec_tool`. It must
   return `GARTNER_GDM`. If the tool is missing, errors, or returns a different account, the
   connector is down — post the "could not run" message below and stop.
3. **Live compute.** `CURRENT_ACCOUNT()` runs on Snowflake's services layer and succeeds even
   when no warehouse is running, so a passing account check does NOT prove you can query data.
   The real test is whether the queries in Steps 2–3 actually execute. If a query fails because
   compute is unavailable — the warehouse won't resume (e.g. Snowflake error `399517`, or errors
   mentioning "cannot be resumed" / warehouse suspend-resume) — that's an infrastructure blocker,
   not a data failure. Post the "could not run" message below and stop.

Treat "could not run" as its own outcome, clearly distinct from a data `FAILURES DETECTED`,
so on-call escalates to infra rather than hunting a data bug. Post to `#sanity-check-testing`
tagging on-call:

```
:rotating_light: *D-000 sanity check — could not run* (<GDM Snowflake connector unavailable | Snowflake compute unavailable>)
On-call: <@oncall>
<one line on what failed — e.g. "Connector is fine (CURRENT_ACCOUNT = GARTNER_GDM) but the task-history query needs a live warehouse; every BA_* warehouse fails to resume with Snowflake error 399517.">
This is an infrastructure blocker, not a data failure — no task-state or max-date result this run.
Needs: ACCOUNTADMIN / warehouse owner (DP_CICD_PROD) to fix warehouse resume, or a Snowflake support case citing the error code.
Ref: DMABGS-3269
```

If the same blocker recurs on consecutive runs, keep posting (it's a live outage worth
surfacing) but stay terse — note "no change since the last run" instead of re-explaining in full.

### Step 1 — Establish the cycle date (key off the last run, not the clock)

Run the `task_states` query first (`references/queries.sql`, section "task_states") and use it
to anchor everything:

- Take the latest run of `D000_CHANNEL_DASHBOARD`. Its `SCHEDULED_TIME` (UTC) is `CYCLE_DATE` —
  the day of the most recent dashboard load.
- `EXPECTED_MAX` = `CYCLE_DATE` − 1.
- `TODAY_UTC` = today's date in UTC. If `CYCLE_DATE` < `TODAY_UTC`, today's run hasn't happened
  yet — treat that as **PENDING**, not a failure. If `CYCLE_DATE` = `TODAY_UTC`, it's a normal
  same-day check.

Anchoring on the actual run rather than the wall clock keeps an early or off-schedule run honest:
it reports "today's cycle pending" instead of false-alarming.

### Step 2 — Evaluate task state

Take the latest non-`SCHEDULED` run of `D000_CHANNEL_DASHBOARD`. It **fails** only if that
run's `STATE` is not `SUCCEEDED` (capture the state + error message) — a genuine problem. Do
**not** fail it merely because today's cycle hasn't started; that's the PENDING case from
Step 1, not an error.

### Step 3 — Max-date check (degrade gracefully if the view isn't there yet)

Before trusting the max-date view, check whether it exists:

```sql
SELECT COLUMN_NAME
FROM BUSINESS_ANALYTICS.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'ANALYTICS_MART'
  AND TABLE_NAME = 'D000_CHANNEL_DASHBOARD_MAX_DATES';
```

If this returns nothing, or is missing expected columns, report "max-date check not available
yet (view pending rollout, see DMABGS-3269)" instead of a failure — do not treat it as a data
problem. Otherwise, run the `max_dates` query (`references/queries.sql`) and compare all seven
returned dates to `EXPECTED_MAX`. Record any that differ (show the actual value, or "no data"
if null).

### Step 3.1 — Value>0 check (freshness isn't enough)

Run the `max_value_check` query (`references/queries.sql`). It returns one row per slice
(overall + Capterra / GetApp / Software Advice + PPC / PPL) with `max_date`, `rev_on_max`, and
`spend_on_max`, read straight from `D000_CHANNEL_DASHBOARD` (`IS_COMPLETE = 1`), so it runs even
if the max-date view isn't deployed yet. A slice **fails** if `max_date` ≠ `EXPECTED_MAX`, or
`rev_on_max` ≤ 0, or `spend_on_max` ≤ 0. This catches a fresh-but-empty slice a date-only check
would pass. It gates the same way the max-date checks do (a real data failure).

### Step 3.2 — Hourly completeness check (GATES — a real data failure)

Freshness and value>0 both look only at the daily total, so a day can land a fresh, non-zero
max date while silently missing several hours of ingestion (a feed interruption, site-tracking
outage, or partial-day load). This check catches that. Run the `hourly_completeness` query
(`references/queries.sql`) with `:expected_max` = `EXPECTED_MAX`. It returns one row per source
stream for `EXPECTED_MAX`:

- **PPC clicks** — ad-platform click ingestion (covers a paid-feed interruption).
- **Sessions** — on-site GA session feed (covers site downtime / tracking outage).

Both read `GDM.PERFORMANCE.GDM_SES_PPC_PPL` — the same source the Step 4 revenue recon matches
to the dollar, so an hour-gap here is a real gap in D-000. Each stream requires all 24 UTC hours
of `EXPECTED_MAX` to clear a low per-hour floor (clicks ≥ 50/hr, sessions ≥ 1000/hr — both far
below the historical hourly minimums, so natural overnight sparsity never trips them). A stream
**fails** if `bad_hours > 0`; report the `bad_hour_list` (the UTC hours that were missing/thin)
and `min_hr_volume`. This gates the same way Step 3.1 does.

Only ever run this against `EXPECTED_MAX` (yesterday), **never today** — the current UTC day is
always incomplete, and PPC clicks in particular lag several hours behind sessions intraday, so
checking today would false-alarm every run. (Anchored on `EXPECTED_MAX`, the day is fully settled
by the ~14:15 UTC run time — verified 24/24 hours on every completed day incl. weekends/holidays.)

### Step 3.5 — Trend / anomaly check (SHADOW MODE — informational only, never gates)

Beyond "did the data land," this checks whether the newly-landed day looks *sane*
versus history: are there unlikely/unwanted swings in the new data compared to
recent same-weekday norms? Run the `anomaly.sql` query (`references/`) as-is —
it returns one row per `channel × measure` (revenue, spend, sessions) for the
latest complete actuals day.

Each row comes back with a `status`: `new-break-up` / `new-break-down` /
`ongoing-up` / `ongoing-down` / `ok` / `insufficient-baseline` / `holiday-suppressed`.
How it decides (all baked into the query, verified against real `GARTNER_GDM` data —
see the backtest note at the bottom of `anomaly.sql` for the numbers):

- **Same-weekday baseline.** Each value is compared to the median of the trailing
  **6 same-weekday** complete days (Mon vs. Mondays), requiring ≥4 valid points.
  Weekday/weekend swings here are huge and channel-specific (Partners and Paid Social
  revenue collapse to ~0 on weekends; PPL revenue ~0 and PPL cost tiny on weekends/
  holidays), so a same-day-of-week comparison is the only honest baseline.
- **Robust band + absolute floor.** Flags when `|robust_z| > 3.5` (median + MAD, so one
  weird past day doesn't poison the band) **and** `|pct deviation| > 15%` **and** the
  baseline median clears a per-measure **absolute floor** ($5k revenue/spend, 5k
  sessions). The absolute floor is what kills small-channel noise (AEO/Referral/Email
  swing hundreds of percent on tiny absolute values a % floor alone can't catch).
- **New-break vs. ongoing-trend.** A flat-median detector fires every day *during* a
  sustained trend because the baseline lags. So the query scores the target day **and**
  the previous eligible day and only calls it a `new-break` when yesterday wasn't
  already flagged the same direction — otherwise `ongoing`. This is what makes it
  actionable (~1 new-break/day vs. ~4 raw flags/day in the backtest).
- **Sessions are de-duplicated.** `SESSIONS` is repeated identically across
  `MONETIZATION_TYPE` (PPC row == PPL row), so summing it naively double-counts 2× — the
  query takes `MAX` per `(date, channel, brand, domain)` grain first. Revenue/spend
  genuinely differ by type and are summed directly. (See Notes → sessions caveat.)
- **US-holiday aware** (`references/us_holidays.md`). If the target day is a US bank
  holiday or weekend, every row is `holiday-suppressed` (a low day is expected, not an
  anomaly). Holidays are also excluded from the baseline so e.g. a Labor Day Monday
  can't drag later Mondays' norms down. (Real check: 2026-09-07 Labor Day naively
  false-flags Organic Search −60%; suppression handles it.)
- **`IS_COMPLETE = 1`** defines the actuals boundary — the table carries forecast rows
  ~2 years into the future, so never key off `MAX(DATE)`.

**This is shadow mode.** It NEVER changes the ✅ / ⏳ / 🚨 header and NEVER adds an
on-call @-mention — it's an observation line only, so the team can watch it for a
tuning week before deciding which cases (if any) should graduate to a real gate.
Surface the **`new-break-*`** rows in the `Trend check (shadow)` block (Step 6); list
any **`ongoing-*`** rows as a demoted one-line footnote (a channel mid-trend shouldn't
re-alarm daily). If nothing broke, say so in one line.

### Step 4 — Reconciliation vs. source, day by day (informational only, never gates)

Two reconciliations, both **day by day over a rolling ~2-month window** — Laurent's post-demo
ask, since a single-day match can hide a mid-window break. Both are in `references/queries.sql`;
both take `:expected_max` = `EXPECTED_MAX`.

- **Revenue** (`revenue_reconciliation`): source `GDM.PERFORMANCE.GDM_SES_PPC_PPL` vs
  `D000_CHANNEL_DASHBOARD` `REVENUE_ACTUALS` (`IS_COMPLETE = 1`). Verified to match to the dollar
  across the window.
- **Spend** (`spend_reconciliation`): source spend table `GDM.MARKETING.SPEND_REPORTING`
  (`AMOUNT_SPENT`) vs `D000_CHANNEL_DASHBOARD` `SPEND_ACTUALS` (`IS_COMPLETE = 1`), compared on the
  **full daily total** — no source/channel scoping. Verified: 0/61 days off across the tested
  window. This is the check that was previously held: the old `CHANNEL_ID` join against the SOT
  reconciled poorly (−6% to −45%) because D-000 uses a different channel taxonomy and the SOT
  lacked Partner/Other; comparing full daily totals against `SPEND_REPORTING` (which carries every
  engine) sidesteps that entirely. D-000 still has no source/engine column, so a per-source spend
  breakdown isn't possible here — that stays in D-001.

Both are informational only — they do NOT change the ✅ / ⏳ / 🚨 header, do NOT add an on-call
@-mention on their own, and are NOT pass/fail checks. Per day, classify by `|pct|`: 🟢 < 10,
🟡 10–15, 🔴 > 15. Report each as a **one-line summary** (don't paste ~60 rows):

- All clean: `Revenue vs. source (60d): ✅ all days within 10%` (same shape for spend)
- Otherwise: `Revenue vs. source (60d): 🔴 N/61 days off >10% — worst <date> <pct>% (src $<x> vs dest $<y>)`,
  listing at most the 2–3 worst days.

To widen the window toward the full fiscal year later, change the `-60` in both queries. The
Step 3.1 spend>0 value check is unaffected (it reads D-000's own `SPEND_ACTUALS`, no source join).

### Step 5 — Determine on-call

Same weekly (Monday-start) rotation as D-001 — Laurent, Yash, Pravin, Shalu, Shubham, Samiksha
rotating. Pick the person whose week-start is the latest date `<=` today. Resolve their Slack
ID for the @-mention (`slack_search_users` by first name → g2.com account); known IDs: Samiksha
`U08P1FZLFL0`, Laurent `U0ABL3UFE07`, Shubham `U0AFQQ52QJC`. Fall back to the plain name if a
Slack ID can't be resolved. Full table in `references/rotation.md`.

### Step 6 — Post the summary to Slack (always, tagging on-call)

Post exactly one `slack_send_message` to channel_id `C0BN4GXJE10` (#sanity-check-testing),
whether everything passed or not — this is a testing channel and the team wants confirmation
either way. Tag the on-call person with `<@USERID>`.

Pick the header from three states:

- `:white_check_mark: All checks passed` — normal same-day run (`CYCLE_DATE` = today), all
  seven max dates = `EXPECTED_MAX` (or the view isn't deployed yet, per Step 3), all six value
  slices have non-zero revenue and spend on their max date, both hourly-completeness streams
  are 24/24 on `EXPECTED_MAX` (Step 3.2), and the task `SUCCEEDED`.
- `:hourglass_flowing_sand: Today's cycle pending — last cycle healthy` — today's run hasn't
  happened yet (`CYCLE_DATE` < today) but everything else checks out. Keep it low-key.
- `:rotating_light: FAILURES DETECTED` — any max date differs from `EXPECTED_MAX`, any value
  slice has zero revenue/spend on its max date, either hourly-completeness stream has a
  thin/missing hour on `EXPECTED_MAX` (Step 3.2), or the task's latest run is not `SUCCEEDED`.
  This is the one that must reach on-call. (The day-by-day reconciliations and the shadow-mode
  trend check are informational and never trigger this state.)

Use this layout — task states go **first** (they're the primary signal), then the max-date
table (or the "not available yet" note):

```
*D-000 sanity check* — <one of the three headers above>
Expected max date: <EXPECTED_MAX>  (dashboard cycle: <CYCLE_DATE>)   ·   On-call: <@oncall>

Task (latest run):
  D000_CHANNEL_DASHBOARD            ·  <SUCCEEDED ✅ | STATE ❌>

Max-date checks: <or "not available yet (view pending rollout, see DMABGS-3269)">
# | Check                          | Max Date  | Status
1 | MAX_DATE_SPEND                 | <date>    | ✅ / ❌
2 | MAX_DATE_SITE                  | <date>    | ✅ / ❌
3 | Spend = Capterra               | <date>    | ✅ / ❌
4 | Spend = GetApp                 | <date>    | ✅ / ❌
5 | Spend = Software Advice        | <date>    | ✅ / ❌
6 | Spend = PPC                    | <date>    | ✅ / ❌
7 | Spend = PPL                    | <date>    | ✅ / ❌

Value>0 checks (revenue & spend on max date):
# | Slice            | Max Date  | Rev | Spend | Status
1 | Overall          | <date>    | >0? | >0?   | ✅ / ❌
2 | Capterra         | <date>    | >0? | >0?   | ✅ / ❌
3 | GetApp           | <date>    | >0? | >0?   | ✅ / ❌
4 | Software Advice  | <date>    | >0? | >0?   | ✅ / ❌
5 | PPC              | <date>    | >0? | >0?   | ✅ / ❌
6 | PPL              | <date>    | >0? | >0?   | ✅ / ❌

Hourly completeness (24 UTC hours on <EXPECTED_MAX>):
  PPC clicks  ·  <✅ 24/24 | ❌ N hr thin/missing: HH,HH (min <min_hr_volume>/hr)>
  Sessions    ·  <✅ 24/24 | ❌ N hr thin/missing: HH,HH (min <min_hr_volume>/hr)>

<if any failure: one line per failing item — stale date, zero value, or thin/missing hours — with the actual numbers>
Revenue vs. source (60d): <one-line summary from Step 4>
Spend vs. source (60d): <one-line summary from Step 4>
Trend check (shadow): <✅ no new breaks | ⚠️ N new break(s): "<channel> <measure> <▲/▼> <today> vs ~<median> same-weekday median (<pct>%)" per new-break row | 🇺🇸 holiday — suppressed>
  <if any ongoing-* rows: "…plus M ongoing trend(s): <channel> <measure> <▲/▼>" on one demoted line>
Ref: DMABGS-3269
```

The header carries the state emoji (from the three states above), so no separate "test"
framing is needed — post it as the real check. Only the `FAILURES DETECTED` state needs to
alarm on-call. Keep the message compact; only expand failing items with detail.

## Notes

- This is read-only against Snowflake — it never writes to the warehouse.
- If a check legitimately lags (e.g. a known weekend delay), that will show as a failure;
  mention it in the summary rather than hiding it, so a human can judge.
- Revenue and spend reconciliations (Step 4) are informational only and never gate pass/fail —
  see "Environment facts" above.
- The trend/anomaly check (Step 3.5) is **shadow mode**: informational only, never gates,
  never pings on-call. It's meant to run for a tuning week before any case is promoted to a
  real gate. Thresholds, the baseline window, the absolute floors, and the new-break/ongoing
  logic are documented at the top of `references/anomaly.sql`; the US-holiday calendar it
  depends on is `references/us_holidays.md` (keep that list current — add the next year each
  January).
- **Data caveat — `SESSIONS` is not additive across `MONETIZATION_TYPE`.** Verified in
  `GARTNER_GDM`: for each `(date, channel, brand, domain_group)` the `SESSIONS` value is
  identical on the PPC and PPL rows (it's a domain-grain metric repeated per monetization
  type). Summing it across that dimension double-counts 2×. `anomaly.sql` de-dups via
  `MAX(SESSIONS)` per grain; any future query touching `SESSIONS` (or pageviews/impressions)
  must do the same. `REVENUE_ACTUALS` / `SPEND_ACTUALS` genuinely differ by type and ARE
  additive.
- **Known live trend (context, not a fault) — Direct sessions surge.** As of Sep 2026,
  de-duplicated Direct sessions have level-shifted ~13× since early July (~319k → ~4.3M/wk),
  almost entirely in `DOMAIN_GROUP = 'TLD'` (~41×; `COM` barely moved), concentrated in the
  Capterra + GetApp brands. A jump that localized reads more like a tracking/classification
  change or bot/crawler influx than broad organic growth — worth confirming with the data
  owner. Until confirmed, expect the trend check to emit `new-break-up` / `ongoing-up` rows
  for Direct sessions on its step-up days; that's the detector working, not a pipeline fault.
- Exact SQL lives in `references/queries.sql` and `references/anomaly.sql`; the rotation table
  in `references/rotation.md`. Read those when running — they hold the authoritative task
  names, column names, thresholds, and schedule.
