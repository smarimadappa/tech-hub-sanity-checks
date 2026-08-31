---
name: d009-sanity-check
description: >-
  Run the daily D-009 Site Performance data-pipeline sanity check and post a
  pass/fail summary to Slack. Use this skill WHENEVER the user asks to run or
  trigger the "D-009 sanity check", "sanity check site performance", check
  whether the D-009 Snowflake tasks ran, confirm the site performance max dates
  are current, or when a scheduled task invokes the daily D-009 check — even if
  phrased loosely (e.g. "did the site perf pipeline land today?", "check D-009",
  "is site performance data fresh?"). It checks the GDM Snowflake + Slack
  connectors and live compute first, verifies the parent and five child D-009
  Snowflake tasks succeeded and the five output table max dates are current, then
  posts the result (tagging the week's on-call) to #sanity-check-testing.
  Prefer this skill over ad-hoc SQL whenever D-009 / site performance monitoring
  is involved.
---

# D-009 Site Performance — daily sanity check

Monitors the D-009 (Site Performance) data pipeline for the GDM analytics team
and reports to Slack. It confirms the pipeline's Snowflake tasks all succeeded
(one parent + five children), and confirms each output table's data is fresh
(MAX(DATE_UTC) = yesterday UTC).

This follows the same pattern as `d000-sanity-check` and `d001-sanity-check` —
same Slack channel, same on-call rotation. Post the result even on success so the
team can trust "no news" isn't just a silent failure.

## Environment facts (do not re-derive)

- **Snowflake:** GDM account, `CURRENT_ACCOUNT()` = `GARTNER_GDM`. Task history
  lives in `BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY`; output tables
  live in `BUSINESS_ANALYTICS.BX_ANALYTICS`. Use the connected Snowflake SQL
  tool (`sql_exec_tool`).
- **Slack destination:** `#sanity-check-testing`, channel_id `C0BN4GXJE10`.
  Post with the Slack `slack_send_message` tool.
- **"Yesterday"** means yesterday in UTC: `DATE_UTC` is the date column in all
  five output tables.
- **Revenue reconciliation is informational only, not a gate** — same caveat as
  D-000/D-001: source vs. destination may not match exactly every day for reasons
  not yet understood. Never gates pass/fail.

## The six Snowflake tasks

All under `BUSINESS_ANALYTICS.BX_ANALYTICS`:

- `D009_SITE_PERF_PV_PARENT` — root task, triggers all children
- `D009_SITE_PERF_PPC_CHILD` — PPC performance table
- `D009_SITE_PERF_PPL_CHILD` — PPL performance table
- `D009_SITE_PERF_CHAT_CHILD` — Chat performance table
- `D009_SITE_PERF_FORMS_CHILD` — Forms performance table
- `D009_SITE_PERF_PV_CHILD` — Pageviews performance table

Each one's latest non-`SCHEDULED` run must be `SUCCEEDED`.

## The five max-date checks

Each output table must have `MAX(DATE_UTC)` = yesterday (UTC):

- `BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPC`
- `BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PPL`
- `BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_CHAT`
- `BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_FORMS`
- `BUSINESS_ANALYTICS.BX_ANALYTICS.D009_SITE_PERF_PV`

## Run the check in this order

### Step 0 — Connector precheck (do this first, always)

You cannot report anything without Slack, and you cannot check anything without
Snowflake, so verify both before doing real work.

1. **Slack.** Confirm the Slack tool is available (e.g. a lightweight
   `slack_search_users` or channel lookup). If Slack is unreachable, stop and
   state clearly that the Slack connector is down and the check could not report.
2. **Snowflake connector (GDM).** Run `SELECT CURRENT_ACCOUNT();` via
   `sql_exec_tool`. It must return `GARTNER_GDM`. If the tool is missing, errors,
   or returns a different account, post the "could not run" message below and stop.
3. **Live compute.** `CURRENT_ACCOUNT()` runs on Snowflake's services layer and
   succeeds even when no warehouse is running. The real test is whether the check
   queries in Steps 2–3 actually execute. If a query fails because compute is
   unavailable (e.g. Snowflake error `399517`, or "cannot be resumed"), that's an
   infrastructure blocker, not a data failure. Post the "could not run" message
   below and stop.

Treat "could not run" as its own outcome, distinct from `FAILURES DETECTED`. Post
to `#sanity-check-testing` tagging on-call:

```
:rotating_light: *D-009 sanity check — could not run* (<GDM Snowflake connector unavailable | Snowflake compute unavailable>)
On-call: <@oncall>
<one line on what failed>
This is an infrastructure blocker, not a data failure — no task-state or max-date result this run.
Needs: ACCOUNTADMIN / warehouse owner (DP_CICD_PROD) to fix warehouse resume, or a Snowflake support case citing the error code.
```

If the same blocker recurs on consecutive runs, keep posting but stay terse —
note "no change since the last run" instead of re-explaining in full.

### Step 1 — Establish the cycle date (key off the last run, not the clock)

Run the `task_states` query first (`references/queries.sql`, section "task_states")
and use it to anchor everything:

- Take the latest run of `D009_SITE_PERF_PV_PARENT`. Its `SCHEDULED_TIME`
  (UTC) is `CYCLE_DATE` — the day of the most recent pipeline run.
- `EXPECTED_MAX` = `CYCLE_DATE` − 1. (A run on day D loads data through D−1.)
- `TODAY_UTC` = today's date in UTC. If `CYCLE_DATE` < `TODAY_UTC`, today's run
  hasn't happened yet — treat that as **PENDING**, not a failure. If `CYCLE_DATE`
  = `TODAY_UTC`, it's a normal same-day check.

### Step 2 — Evaluate task states

For each of the six tasks (parent + five children), take the latest non-`SCHEDULED`
run. A task **fails** only if that run's `STATE` is not `SUCCEEDED` (capture state
+ error message). Do **not** fail a task merely because today's cycle hasn't
started — that's the PENDING case from Step 1.

### Step 3 — Max-date check

Run the `max_dates` query (`references/queries.sql`). Compare each of the five
returned dates to `EXPECTED_MAX`. Record any that differ (show the actual value,
or "no data" if null).

### Step 4 — Revenue reconciliation vs. source (informational only, never gates pass/fail)

Run `revenue_reconciliation` plus `revenue_reconciliation_destination` (both in
`references/queries.sql`) for `EXPECTED_MAX`. Sum `ppc_revenue + ppl_revenue`
(treat NULL as 0) and compare to `destination_revenue`.

This is informational only — it does NOT change the ✅ / ⏳ / 🚨 header, does NOT
add an on-call @-mention on its own, and is NOT itself a pass/fail check. Report
it as one line at the end of the Slack message:

- Exact match: `Revenue vs. source: ✅ exact match ($<destination_revenue>)`
- Mismatch: `Revenue vs. source: <indicator> source $<ppc+ppl> vs. destination $<destination_revenue> (off by $<diff>, <pct>%)`
  where `<indicator>` is 🟢 if `<pct>` < 10, 🟡 if 10–15, 🔴 if > 15

### Step 5 — Determine on-call

Weekly rotation, weeks start Monday. Pick the person whose week-start is the
latest date `<=` today (IST). Resolve their Slack ID for the @-mention
(`slack_search_users` by first name → g2.com account); known IDs: Samiksha
`U08P1FZLFL0`, Laurent `U0ABL3UFE07`, Shubham `U0AFQQ52QJC`. Fall back to the
plain name if a Slack ID can't be resolved. Full table in `shared/rotation.md`
(repo root).

### Step 6 — Post the summary to Slack (always, tagging on-call)

Post exactly one `slack_send_message` to channel_id `C0BN4GXJE10`
(#sanity-check-testing), whether everything passed or not. Tag the on-call person
with `<@USERID>`.

Pick the header from three states:

- `:white_check_mark: All checks passed` — normal same-day run (`CYCLE_DATE` =
  today), all five max dates = `EXPECTED_MAX`, all six tasks `SUCCEEDED`.
- `:hourglass_flowing_sand: Today's cycle pending — last cycle healthy` — today's
  run hasn't happened yet (`CYCLE_DATE` < today) but everything else checks out.
  Keep it low-key.
- `:rotating_light: FAILURES DETECTED` — any max date differs from `EXPECTED_MAX`,
  or any task's latest run is not `SUCCEEDED`. This is the one that must reach
  on-call.

Use this layout — task states go **first** (they're the primary signal), then the
max-date table:

```
*D-009 sanity check* — <one of the three headers above>
Expected max date: <EXPECTED_MAX>  (pipeline cycle: <CYCLE_DATE>)   ·   On-call: <@oncall>

Tasks (latest run):
  D009_SITE_PERF_PV_PARENT    ·  <SUCCEEDED ✅ | STATE ❌>
  D009_SITE_PERF_PPC_CHILD    ·  <SUCCEEDED ✅ | STATE ❌>
  D009_SITE_PERF_PPL_CHILD    ·  <SUCCEEDED ✅ | STATE ❌>
  D009_SITE_PERF_CHAT_CHILD   ·  <SUCCEEDED ✅ | STATE ❌>
  D009_SITE_PERF_FORMS_CHILD  ·  <SUCCEEDED ✅ | STATE ❌>
  D009_SITE_PERF_PV_CHILD     ·  <SUCCEEDED ✅ | STATE ❌>

Max-date checks:
# | Table          | Max DATE_UTC | Status
1 | PPC            | <date>       | ✅ / ❌
2 | PPL            | <date>       | ✅ / ❌
3 | Chat           | <date>       | ✅ / ❌
4 | Forms          | <date>       | ✅ / ❌
5 | Pageviews (PV) | <date>       | ✅ / ❌

<if any failure: one line per failing item with the actual state/date and any error message>
Revenue vs. source: <exact match, or the off-by line from Step 4>
```

The header carries the state emoji, so no separate "test" framing is needed —
post it as the real check. Only the `FAILURES DETECTED` state needs to alarm
on-call. Keep the message compact; only expand failing items with detail.

## Notes

- This is read-only against Snowflake — it never writes to the warehouse.
- If a check legitimately lags (e.g. a known weekend delay), that will show as a
  failure; mention it in the summary rather than hiding it, so a human can judge.
- Revenue reconciliation (Step 4) is informational only and never gates pass/fail.
- Exact SQL lives in `references/queries.sql`; the rotation table in
  `shared/rotation.md` (repo root). Read those when running — they hold the
  authoritative task names, column names, and schedule.
- The `REVENUE` column name in the destination query (`references/queries.sql`)
  should be verified against real table schema on first run.
