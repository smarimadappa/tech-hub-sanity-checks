---
name: d000-sanity-check
description: >-
  Run the daily D-000 Channel Dashboard data-pipeline sanity check (Jira DMABGS-3269) and post
  a pass/fail summary to Slack. Use this skill WHENEVER the user asks to run or trigger the
  "D-000 sanity check", "sanity check the channel dashboard", check whether the
  GDM_SPEND_IMPR_CLICKS or GDM_CHANNEL_DASHBOARD_V3 Snowflake tasks ran, confirm the D-000 max
  dates are current, or when a scheduled task invokes the daily D-000 check — even if phrased
  loosely (e.g. "is the channel dashboard fresh?", "did spend/impressions/clicks load today?",
  "check the D-000 pipeline"). It checks the GDM Snowflake + Slack connectors and live compute
  first, verifies the five D-000 Snowflake tasks succeeded, checks the
  D000_CHANNEL_DASHBOARD_MAX_DATES view (degrading gracefully if that view isn't deployed yet),
  then posts the result (tagging the week's on-call) to #sanity-check-testing. Prefer this skill
  over ad-hoc SQL whenever D-000 / channel dashboard monitoring is involved.
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
- **Revenue reconciliation is informational only, not a gate:** verified against real data in
  `GARTNER_GDM` — the source (`GDM.PERFORMANCE.GDM_SES_PPC_PPL`) vs. destination formula matches
  exactly on most days but not every day, for reasons not yet understood (checked
  `GDM_CHANNEL_DASHBOARD_CORRECTION_DATA` — no rows for the mismatching date, so that's not it).
  Because of that unexplained variance, it must never gate pass/fail or page on-call — see Step 4.
- **Max-date view rollout:** `D000_CHANNEL_DASHBOARD_MAX_DATES` is being rolled out via a
  companion ticket and may not exist yet. A missing view is never a data failure — see Step 3.
- **Keep in sync:** the on-call rotation table in `references/rotation.md` must stay identical
  to `d001-sanity-check`'s copy (same team, same channel). They are independent files with no
  automatic sharing — update both by hand.

## The five Snowflake tasks

All under database `BUSINESS_ANALYTICS`, schema `CHANNEL_ANALYTICS` except the last:

- `GDM_SPEND_IMPR_CLICKS_DELETE` (CHANNEL_ANALYTICS)
- `GDM_SPEND_IMPR_CLICKS_INSERT` (CHANNEL_ANALYTICS)
- `GDM_CHANNEL_DASHBOARD_V3_DELETE` (CHANNEL_ANALYTICS)
- `GDM_CHANNEL_DASHBOARD_V3_INSERT` (CHANNEL_ANALYTICS)
- `D000_CHANNEL_DASHBOARD` (ANALYTICS_MART) — calls `SP_CHANNEL_DASHBOARD()`

Each one's latest non-`SCHEDULED` run must be `SUCCEEDED`.

## The seven max-date checks

Once the view exists, each of these must equal yesterday (UTC): `MAX_DATE_SPEND`,
`MAX_DATE_SITE`, `max_date_spend_capterra`, `max_date_spend_getapp`,
`max_date_spend_software_advice`, `max_date_spend_ppc`, `max_date_spend_ppl`.

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

### Step 2 — Evaluate task states

For each of the five tasks, take the latest non-`SCHEDULED` run. A task **fails** only if that
run's `STATE` is not `SUCCEEDED` (capture the state + error message) — a genuine problem. Do
**not** fail a task merely because today's cycle hasn't started; that's the PENDING case from
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

### Step 4 — Revenue reconciliation vs. source (informational only, never gates pass/fail)

Run `revenue_reconciliation` plus `revenue_reconciliation_destination` (both in
`references/queries.sql`) for `EXPECTED_MAX`. Sum `ppc_revenue + ppl_revenue` (treat NULL as 0)
and compare to `destination_revenue`.

This is informational only — it does NOT change the ✅ / ⏳ / 🚨 header, does NOT add an
on-call @-mention on its own, and is NOT itself a pass/fail check. (Verified against real data:
the source/destination formula matches exactly most days but not every day for reasons not yet
understood — see `references/queries.sql` comment — so treat any mismatch as a note, not a fault.)
Report it as one line at the end of the Slack message:

- Exact match: `Revenue vs. source: ✅ exact match ($<destination_revenue>)`
- Mismatch: `Revenue vs. source: source $<ppc+ppl> vs. destination $<destination_revenue> (off by $<diff>, <pct>%)`

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
  seven max dates = `EXPECTED_MAX` (or the view isn't deployed yet, per Step 3), and all five
  tasks `SUCCEEDED`.
- `:hourglass_flowing_sand: Today's cycle pending — last cycle healthy` — today's run hasn't
  happened yet (`CYCLE_DATE` < today) but everything else checks out. Keep it low-key.
- `:rotating_light: FAILURES DETECTED` — any max date differs from `EXPECTED_MAX`, or any
  task's latest run is not `SUCCEEDED`. This is the one that must reach on-call.

Use this layout — task states go **first** (they're the primary signal), then the max-date
table (or the "not available yet" note):

```
*D-000 sanity check* — <one of the three headers above>
Expected max date: <EXPECTED_MAX>  (dashboard cycle: <CYCLE_DATE>)   ·   On-call: <@oncall>

Tasks (latest run):
  GDM_SPEND_IMPR_CLICKS_DELETE      ·  <SUCCEEDED ✅ | STATE ❌>
  GDM_SPEND_IMPR_CLICKS_INSERT      ·  <SUCCEEDED ✅ | STATE ❌>
  GDM_CHANNEL_DASHBOARD_V3_DELETE   ·  <SUCCEEDED ✅ | STATE ❌>
  GDM_CHANNEL_DASHBOARD_V3_INSERT   ·  <SUCCEEDED ✅ | STATE ❌>
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

<if any failure: one line per failing item with the actual state/date and any error message>
Revenue vs. source: <exact match, or the off-by line from Step 4>
Ref: DMABGS-3269
```

The header carries the state emoji (from the three states above), so no separate "test"
framing is needed — post it as the real check. Only the `FAILURES DETECTED` state needs to
alarm on-call. Keep the message compact; only expand failing items with detail.

## Notes

- This is read-only against Snowflake — it never writes to the warehouse.
- If a check legitimately lags (e.g. a known weekend delay), that will show as a failure;
  mention it in the summary rather than hiding it, so a human can judge.
- Revenue reconciliation (Step 4) is informational only and never gates pass/fail — see
  "Environment facts" above.
- Exact SQL lives in `references/queries.sql`; the rotation table in `references/rotation.md`.
  Read those when running — they hold the authoritative task names, column names, and schedule.
