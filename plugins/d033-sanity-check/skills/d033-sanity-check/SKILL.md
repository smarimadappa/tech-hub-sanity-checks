---
name: d033-sanity-check
description: >-
  Run the daily D-033 BX Self-Service Tool data-pipeline sanity check (Jira
  DMABGS-3271) and post a pass/fail summary to Slack. Use this skill WHENEVER the
  user asks to run or trigger the "D-033 sanity check", "sanity check the BX
  self-service tool", check whether the D-033 Snowflake tasks ran, confirm the BX
  self-service max date is current, or when a scheduled task invokes the daily
  D-033 check — even if phrased loosely (e.g. "did the BX self-service pipeline
  land today?", "check D-033", "is the self-service tool data fresh?"). It checks
  the GDM Snowflake + Slack connectors and live compute first, verifies the two
  D-033 Snowflake tasks (delete + insert) succeeded and the output table's max
  date is current with non-zero revenue per brand, then posts the result (tagging
  the week's on-call) to #sanity-check-testing. Prefer this skill over ad-hoc SQL
  whenever D-033 / BX self-service tool monitoring is involved.
---

# D-033 BX Self-Service Tool — daily sanity check

Monitors the D-033 (BX Self-Service Tool) data pipeline for the GDM analytics team
and reports to Slack. It confirms the pipeline's two Snowflake tasks succeeded
(delete + insert), and confirms the output table's data is fresh
(`MAX(DATE_UTC)` = yesterday UTC) and non-empty across brands.

This follows the same pattern as `d000-sanity-check`, `d001-sanity-check`, and
`d009-sanity-check` — same Slack channel, same on-call rotation. Post the result
even on success so the team can trust "no news" isn't just a silent failure.

## Environment facts (do not re-derive)

- **Snowflake:** GDM account, `CURRENT_ACCOUNT()` = `GARTNER_GDM`. Task history
  lives in `BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY`; the output table
  lives in `BUSINESS_ANALYTICS.BX_ANALYTICS`. Use the connected Snowflake SQL
  tool (`sql_exec_tool`).
- **Slack destination:** `#sanity-check-testing`, channel_id `C0BN4GXJE10`.
  Post with the Slack `slack_send_message` tool.
- **Final table:** `BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST`
  — note the `_ST` suffix; a plain `D033_BX_SELF_SERVICE_TOOL` table does **not**
  exist. Date column is `DATE_UTC`.
- **"Yesterday"** means yesterday in UTC.
- **Dimensions:** `BRAND` ∈ {Capterra, GetApp, Software Advice} × `CHANNEL` ∈
  {Paid, Unpaid}. Monetization type is the PPC vs PPL revenue split. GetApp is
  PPC-only (no PPL) — don't expect PPL revenue for it.
- **Revenue reconciliation is informational only, not a gate** — same caveat as
  D-000/D-001/D-009: source vs. destination may not match exactly every day for
  reasons not yet fully understood. Never gates pass/fail.

## The two Snowflake tasks

Both under `BUSINESS_ANALYTICS.BX_ANALYTICS`:

- `D033_BX_SELF_SERVICE_TOOL_DELETE_ST` — delete step (clears the reload window)
- `D033_BX_SELF_SERVICE_TOOL_INSERT_ST` — insert step (reloads the table)

They run in sequence (~14:30 UTC / 07:30 America/Los_Angeles). Each one's latest
non-`SCHEDULED` run must be `SUCCEEDED`.

## The freshness + value check

Against `BUSINESS_ANALYTICS.BX_ANALYTICS.D033_BX_SELF_SERVICE_TOOL_ST`:

1. **Max date:** `MAX(DATE_UTC)` = yesterday (UTC) = `EXPECTED_MAX`.
2. **Value > 0 (fresh-but-empty guard):** on `EXPECTED_MAX`, overall PPC revenue
   > 0, overall PPL revenue > 0, and each of the three brands has combined
   revenue > 0 **and** sessions > 0. This catches a refresh that lands a current
   date but empty numbers. (Don't require PPL > 0 *per brand* — GetApp has no PPL.)

Use `PAGE_PPC_REVENUE` / `PAGE_PPL_REVENUE` for revenue; the `LAND_*` columns
mirror them at this grain, so summing both would double-count.

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
   queries in Steps 2–4 actually execute. If a query fails because compute is
   unavailable (e.g. Snowflake error `399517`, or "cannot be resumed"), that's an
   infrastructure blocker, not a data failure. Post the "could not run" message
   below and stop.

Treat "could not run" as its own outcome, distinct from `FAILURES DETECTED`. Post
to `#sanity-check-testing` tagging on-call:

```
:rotating_light: *D-033 sanity check — could not run* (<GDM Snowflake connector unavailable | Snowflake compute unavailable>)
On-call: <@oncall>
<one line on what failed>
This is an infrastructure blocker, not a data failure — no task-state or max-date result this run.
Needs: ACCOUNTADMIN / warehouse owner to fix warehouse resume, or a Snowflake support case citing the error code.
```

If the same blocker recurs on consecutive runs, keep posting but stay terse —
note "no change since the last run" instead of re-explaining in full.

### Step 1 — Establish the cycle date (key off the last run, not the clock)

Run the `task_states` query first (`references/queries.sql`, section "task_states")
and use it to anchor everything:

- Take the latest run of `D033_BX_SELF_SERVICE_TOOL_INSERT_ST`. Its
  `SCHEDULED_TIME` (UTC) is `CYCLE_DATE` — the day of the most recent pipeline run.
- `EXPECTED_MAX` = `CYCLE_DATE` − 1. (A run on day D loads data through D−1.)
- `TODAY_UTC` = today's date in UTC. If `CYCLE_DATE` < `TODAY_UTC`, today's run
  hasn't happened yet — treat that as **PENDING**, not a failure. If `CYCLE_DATE`
  = `TODAY_UTC`, it's a normal same-day check.

### Step 2 — Evaluate task states

For both tasks (delete + insert), take the latest non-`SCHEDULED` run. A task
**fails** only if that run's `STATE` is not `SUCCEEDED` (capture state + error
message). Do **not** fail a task merely because today's cycle hasn't started —
that's the PENDING case from Step 1.

### Step 3 — Max-date + value check

Run the `max_date` query, then the `value_check` query (both in
`references/queries.sql`) for `EXPECTED_MAX`:

- Compare `MAX(DATE_UTC)` to `EXPECTED_MAX` (show the actual value, or "no data"
  if null).
- From `value_check`: the ROLLUP `BRAND = NULL` row is the overall total — assert
  overall PPC revenue > 0 and overall PPL revenue > 0. Each of the three named
  brand rows must have `total_revenue` > 0 and `sessions` > 0. Record any that
  fail (brand, actual values).

### Step 4 — Revenue reconciliation vs. source, day by day (informational only)

Run `revenue_reconciliation` (in `references/queries.sql`, takes `:expected_max` =
`EXPECTED_MAX`). It compares **PPC+PPL unified into one revenue total per day**,
**day by day over a rolling ~2-month window** (not just the last day — a single-day
match can hide a mid-window break), matching how D-000/D-001/D-009 report.

Source `GDM.PERFORMANCE.GDM_SES_PPC_PPL` (BRAND_ID 1/2/3) vs destination
`PAGE_PPC_REVENUE + PAGE_PPL_REVENUE`. Attribution basis is verified to the dollar
day-by-day: **PPC by click date, PPL by _conversion_ date** (the destination attributes
`PAGE_PPL_REVENUE` by conversion date — qual date is materially off day-by-day and only
reconciles in aggregate, so don't switch it back). Verified 2026-09-13: 0/61 days off
>10%, totals within -0.3%.

This is informational only — it does NOT change the ✅ / ⏳ / 🚨 header, does NOT add
an on-call @-mention on its own, and is NOT itself a pass/fail check. (Source vs.
destination can diverge on a given day for reasons not always understood — treat any
mismatch as a note, not a fault.) Per day, classify by `|pct|`: 🟢 < 10, 🟡 10–15,
🔴 > 15. Report it as a **one-line summary** at the end of the Slack message (don't
paste 60 rows):

- All clean: `Revenue vs. source (60d): ✅ all days within 10%`
- Otherwise: `Revenue vs. source (60d): 🔴 3/61 days off >10% — worst <date> <pct>% (src $<x> vs dest $<y>)`
  listing at most the 2–3 worst days.

To widen the window toward the full fiscal year later, change the `-60` in the query.

**No spend reconciliation for D-033** (unlike D-000/D-001, which reconcile spend vs.
`GDM.MARKETING.SPEND_REPORTING`): D-033 is a *self-service page-performance* pipeline — its output
table `D033_BX_SELF_SERVICE_TOOL_ST` carries sessions and PPC/PPL *revenue* per page, but **no
media spend**. Ad spend only exists on the acquisition side (D-000 channel dashboard / D-001 cube),
so there is no destination-side spend column here to reconcile against.

### Step 5 — Determine on-call

Weekly rotation, weeks start Monday. Pick the person whose week-start is the
latest date `<=` today (IST). Resolve their Slack ID for the @-mention
(`slack_search_users` by first name → g2.com account); known IDs: Samiksha
`U08P1FZLFL0`, Laurent `U0ABL3UFE07`, Shubham `U0AFQQ52QJC`, Shalu `U0ABL3956UX`.
Fall back to the plain name if a Slack ID can't be resolved. Full table in
`references/rotation.md`.

### Step 6 — Post the summary to Slack (always, tagging on-call)

Post exactly one `slack_send_message` to channel_id `C0BN4GXJE10`
(#sanity-check-testing), whether everything passed or not. Tag the on-call person
with `<@USERID>`.

Pick the header from three states:

- `:white_check_mark: All checks passed` — normal same-day run (`CYCLE_DATE` =
  today), max date = `EXPECTED_MAX`, both tasks `SUCCEEDED`, and all value checks
  non-zero.
- `:hourglass_flowing_sand: Today's cycle pending — last cycle healthy` — today's
  run hasn't happened yet (`CYCLE_DATE` < today) but everything else checks out.
  Keep it low-key.
- `:rotating_light: FAILURES DETECTED` — max date differs from `EXPECTED_MAX`, a
  task's latest run is not `SUCCEEDED`, or a value check is zero/empty. This is the
  one that must reach on-call.

Use this layout — task states go **first** (they're the primary signal), then the
freshness/value table:

```
*D-033 sanity check* — <one of the three headers above>
Expected max date: <EXPECTED_MAX>  (pipeline cycle: <CYCLE_DATE>)   ·   On-call: <@oncall>

Tasks (latest run):
  D033_BX_SELF_SERVICE_TOOL_DELETE_ST  ·  <SUCCEEDED ✅ | STATE ❌>
  D033_BX_SELF_SERVICE_TOOL_INSERT_ST  ·  <SUCCEEDED ✅ | STATE ❌>

Freshness + value (on <EXPECTED_MAX>):
  Max DATE_UTC       ·  <date>  ✅ / ❌
  PPC revenue        ·  $<overall ppc>  ✅ / ❌
  PPL revenue        ·  $<overall ppl>  ✅ / ❌
  Capterra           ·  $<total>  ·  <sessions> sess  ✅ / ❌
  GetApp             ·  $<total>  ·  <sessions> sess  ✅ / ❌
  Software Advice    ·  $<total>  ·  <sessions> sess  ✅ / ❌

<if any failure: one line per failing item with the actual state/date/value and any error message>
Revenue vs. source (60d): <one-line summary from Step 4>
```

The header carries the state emoji, so no separate "test" framing is needed —
post it as the real check. Only the `FAILURES DETECTED` state needs to alarm
on-call. Keep the message compact; only expand failing items with detail.

## Notes

- This is read-only against Snowflake — it never writes to the warehouse.
- If a check legitimately lags (e.g. a known weekend delay), that will show as a
  failure; mention it in the summary rather than hiding it, so a human can judge.
- Revenue reconciliation (Step 4) is informational only and never gates pass/fail.
  It unifies PPC+PPL day-by-day over a 60-day window (PPC by click date, PPL by
  conversion date) — verified to reconcile to the dollar, so a run of off-days is a
  real signal worth a look, not expected noise.
- Exact SQL lives in `references/queries.sql`; the rotation table in
  `references/rotation.md`. Read those when running — they hold the authoritative
  task names, column names, brand→id mapping, and schedule.
- The output table is `..._ST` (there is no un-suffixed `D033_BX_SELF_SERVICE_TOOL`).
  `PAGE_*` and `LAND_*` revenue columns mirror each other — use `PAGE_*` only.
