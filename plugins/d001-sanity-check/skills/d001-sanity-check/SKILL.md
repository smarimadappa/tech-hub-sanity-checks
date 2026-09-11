---
name: d001-sanity-check
description: >-
  Run the daily D-001 Performance Cube data-pipeline sanity check (Jira DMABGS-3270)
  and post a pass/fail summary to Slack. Use this skill WHENEVER the user asks to run
  or trigger the "D-001 sanity check", "sanity check the performance cube", "check the
  MDD pipeline", verify the D-001 Snowflake tasks ran, confirm the cube's max dates are
  current, or when a scheduled task invokes the daily D-001 check — even if they phrase
  it loosely (e.g. "did the cube refresh land today?", "is the GDM data fresh?", "run
  the tech-hub sanity check"). It checks the GDM Snowflake + Slack connectors and live
  compute first, verifies the two D-001 Snowflake tasks (cube refresh + MDD) succeeded and
  the six max-date checks are current, then posts the result (tagging the week's on-call) to
  #sanity-check-testing.
  Prefer this skill over ad-hoc SQL whenever D-001 / performance cube / MDD monitoring
  is involved.
---

# D-001 Performance Cube — daily sanity check

Monitors the D-001 (Performance Cube) data pipeline for the GDM analytics team and
reports to Slack. It replaces two hand-run checks with one pass: confirm the pipeline's
Snowflake tasks all succeeded, and confirm the cube's data is fresh (max date = yesterday)
overall and across each brand and monetization type. Jira reference: **DMABGS-3270**.

The point of the check is early warning: Andrea's daily reporting depends on D-001, and
the cube has a history of refresh timeouts, so a red flag needs to reach the on-call
person fast. Post the result even on success so the team can trust "no news" isn't just
a silent failure.

## Environment facts (do not re-derive)

- **Snowflake:** GDM account, `CURRENT_ACCOUNT()` = `GARTNER_GDM`. The check reads from
  `BUSINESS_ANALYTICS.BX_ANALYTICS.D001_PERFORMANCE_CUBE` and task history via
  `BUSINESS_ANALYTICS.INFORMATION_SCHEMA.TASK_HISTORY`. Use the connected Snowflake SQL
  tool (`sql_exec_tool`).
- **Slack destination:** `#sanity-check-testing`, channel_id `C0BN4GXJE10`. Post with the
  Slack `slack_send_message` tool.
- **Refresh timing (IST):** cube refresh ~17:30, MDD ~19:00. Run the check after both
  (≈19:15 IST) so both tasks and the day's data are present.
- **"Yesterday"** means yesterday in IST: `TZ=Asia/Kolkata date -d "yesterday" +%F`.

## The two Snowflake tasks

Both under database `BUSINESS_ANALYTICS`:

- `D001_PERFORMANCE_CUBE_REFRESH` (BX_ANALYTICS) — daily ~17:30 IST
- `MDD_CAMPAIGN_REFERENCE_INSERT` (CHANNEL_ANALYTICS) — daily ~19:00 IST

Both are daily: their latest run must be `SUCCEEDED` and dated *today* (IST) on a normal
same-day run. (The hourly `SUPERSET_INSERT`/`SUPERSET_DELETE` tasks are intentionally not
monitored — they're not the freshness-critical steps.)

## The six max-date checks (freshness **and** non-zero value)

Six slices: overall, `BRAND` in Capterra / GetApp / Software Advice, and `MONETIZATION_TYPE`
in PPC / PPL. Each slice must (a) have `MAX_DATE` = yesterday (IST) **and** (b) have non-zero
`REVENUE` **and** `SPEND` on that max date. The value>0 half is Laurent's post-demo ask: a
slice can land a fresh date with all-zero revenue/spend (a silent partial failure) that a
date-only check sails past. Both PPC and PPL genuinely carry spend, so spend>0 applies to
every slice — verified against real data.

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
3. **Live compute.** Important subtlety: `CURRENT_ACCOUNT()` runs on Snowflake's services
   layer and succeeds *even when no warehouse is running*, so a passing account check does
   NOT prove you can query data. The real test is whether the check queries in Steps 2–3
   actually execute. If a query fails because compute is unavailable — the warehouse won't
   resume (e.g. Snowflake error `399517`, or errors mentioning "cannot be resumed" /
   warehouse suspend-resume) — that's an infrastructure blocker, not a data failure. Post the
   "could not run" message below and stop.

Treat "could not run" as its own outcome, clearly distinct from a data `FAILURES DETECTED`,
so on-call escalates to infra rather than hunting a data bug. Post to `#sanity-check-testing`
tagging on-call:

```
:rotating_light: *D-001 sanity check — could not run* (<GDM Snowflake connector unavailable | Snowflake compute unavailable>)
On-call: <@oncall>
<one line on what failed — e.g. "Connector is fine (CURRENT_ACCOUNT = GARTNER_GDM) but both queries need a live warehouse; every BA_* warehouse fails to resume with Snowflake error 399517.">
This is an infrastructure blocker, not a data failure — no task-state or max-date result this run.
Needs: ACCOUNTADMIN / warehouse owner (DP_CICD_PROD) to fix warehouse resume, or a Snowflake support case citing the error code.
Ref: DMABGS-3270
```

If the same blocker recurs on consecutive runs, keep posting (it's a live outage worth
surfacing) but stay terse — note "no change since the last run" instead of re-explaining in full.

### Step 1 — Establish the cycle date (key off the last refresh, not the clock)

Run the `task_states` query first (`references/queries.sql`, section "task_states") and use it to anchor everything:

- Take the latest run of `D001_PERFORMANCE_CUBE_REFRESH`. Its `SCHEDULED_TIME` converted to IST is `CYCLE_DATE` — the day of the most recent cube refresh.
- `EXPECTED_MAX` = `CYCLE_DATE` − 1. (A refresh on day D loads data through D−1.)
- `TODAY_IST` = today's date in IST. If `CYCLE_DATE` < `TODAY_IST`, today's refresh hasn't run yet — treat that as **PENDING**, not a failure. If `CYCLE_DATE` = `TODAY_IST`, it's a normal same-day check.

Anchoring on the actual refresh rather than the wall clock keeps an early or off-schedule run honest: it reports "today's cycle pending" instead of false-alarming. On the normal 19:15 IST schedule `CYCLE_DATE` = today, so `EXPECTED_MAX` = yesterday, exactly as expected.

### Step 2 — Evaluate task states

For each of the two tasks, take the latest non-`SCHEDULED` run. A task **fails** only if that run's `STATE` is not `SUCCEEDED` (capture the state + error message) — a genuine problem. Do **not** fail a task merely because today's cycle hasn't started; that's the PENDING case from Step 1, not an error.

### Step 3 — Max-date check (freshness + value>0)

Run the `max_dates` query in `references/queries.sql` — it returns one row per slice with
`max_date`, `rev_on_max`, and `spend_on_max`. For each of the six slices, a **failure** is
either: `max_date` ≠ `EXPECTED_MAX`, **or** `rev_on_max` ≤ 0, **or** `spend_on_max` ≤ 0.
Record what failed (stale date, or zero-value) with the actual numbers (or "no data" if null).

### Step 4 — Reconciliation vs. source, day by day (informational only, never gates pass/fail)

Two reconciliations, both **day by day over a rolling ~2-month window** (not just the last
day — Laurent's post-demo ask: a single-day match can hide a mid-window break). Both are in
`references/queries.sql`; both take `:expected_max` = `EXPECTED_MAX`.

- **Revenue** (`revenue_reconciliation`): source `GDM.PERFORMANCE.GDM_SES_PPC_PPL` vs cube
  `REVENUE`, per day. Verified to match to the dollar across the window.
- **Spend** (`spend_reconciliation`): source spend table `GDM.MARKETING.SPEND_REPORTING`
  (`AMOUNT_SPENT`) vs cube `SPEND`, per day, compared on the **full daily total** — no
  source-scoping needed. `SPEND_REPORTING` is the granular source of truth (per date × source ×
  channel × brand × campaign) and carries every engine including Partner, so its daily total
  equals the cube's `SPEND` to the dollar. Verified: 0/61 days off across the tested window.
  (Replaces the old `SPEND_RECONCILIATION.SOT_SPEND` per-source join, which only tracked the
  paid-media engines and needed scoping to match.)

Both are informational only — they do NOT change the ✅ / ⏳ / 🚨 header, do NOT add an on-call
@-mention on their own, and are NOT pass/fail checks. (Source vs. destination can diverge on a
given day for reasons not always understood — treat any mismatch as a note, not a fault.) Per
day, classify by `|pct|`: 🟢 < 10, 🟡 10–15, 🔴 > 15. Report each as a **one-line summary** at
the end of the Slack message (don't paste 60 rows):

- All clean: `Revenue vs. source (60d): ✅ all days within 10%` (same shape for spend)
- Otherwise: `Revenue vs. source (60d): 🔴 3/61 days off >10% — worst <date> <pct>% (src $<x> vs dest $<y>)`
  listing at most the 2–3 worst days.

To widen the window toward the full fiscal year later, change the `-60` in both queries.

### Step 4.5 — Per-source spend check (HELD — pending Shubham)

Laurent flagged that a bare "spend > 0" won't catch one engine (e.g. Bing) dying while another
(Google) keeps the total positive, and that D-001 is the right home because it carries the
`SOURCE` dimension. The `spend_by_source` block in `references/queries.sql` sketches the check
but is intentionally **not wired in**: it needs agreement (with Shubham) on which sources are
"must-be-nonzero daily" vs. intermittent (Quora/Reddit/DV360 are sparse and would false-alarm).
Do not gate or report on it until that's settled.

### Step 5 — Determine on-call

Weekly rotation, weeks start Monday. Pick the person whose week-start is the latest date
that is `<=` today (IST). Resolve their Slack ID for the @-mention (`slack_search_users`
by first name → g2.com account; fall back to the known IDs below; if none, use the plain
name). Rotation and known IDs are in `references/rotation.md`.

### Step 6 — Post the summary to Slack (always, tagging on-call)

Post exactly one `slack_send_message` to channel_id `C0BN4GXJE10` (#sanity-check-testing),
whether everything passed or not — this is a testing channel and the team wants confirmation
either way. Tag the on-call person with `<@USERID>`.

Pick the header from three states:

- `:white_check_mark: All checks passed` — normal same-day run (`CYCLE_DATE` = today), all six slices fresh (`max_date` = `EXPECTED_MAX`) with non-zero revenue and spend, both tasks `SUCCEEDED`.
- `:hourglass_flowing_sand: Today's cycle pending — last cycle healthy` — today's refresh hasn't run yet (`CYCLE_DATE` < today) but everything matches `EXPECTED_MAX` and no task run has failed. This is the honest "not a problem, just early" state; keep it low-key (no @-mention needed, or mention without alarm).
- `:rotating_light: FAILURES DETECTED` — any slice is stale (`max_date` ≠ `EXPECTED_MAX`) or has zero revenue/spend on its max date, or any task's latest run is not `SUCCEEDED`. This is the one that must reach on-call. (The day-by-day source reconciliations in Step 4 are informational and never trigger this state.)

Use this layout — task states go **first** (they're the primary signal), then the max-date table:

```
*D-001 sanity check* — <one of the three headers above>
Expected max date: <EXPECTED_MAX>  (cube refresh cycle: <CYCLE_DATE>)   ·   On-call: <@oncall>

Tasks (latest run):
  D001_PERFORMANCE_CUBE_REFRESH  ·  <SUCCEEDED ✅ | STATE ❌>
  MDD_CAMPAIGN_REFERENCE_INSERT  ·  <SUCCEEDED ✅ | STATE ❌>

Max-date checks (date fresh + revenue>0 + spend>0):
# | Check                  | Max Date  | Rev   | Spend | Status
1 | Overall                | <date>    | >0?   | >0?   | ✅ / ❌
2 | Brand = Capterra       | <date>    | >0?   | >0?   | ✅ / ❌
3 | Brand = GetApp         | <date>    | >0?   | >0?   | ✅ / ❌
4 | Brand = Software Advice| <date>    | >0?   | >0?   | ✅ / ❌
5 | Monetization = PPC     | <date>    | >0?   | >0?   | ✅ / ❌
6 | Monetization = PPL     | <date>    | >0?   | >0?   | ✅ / ❌

<if any failure: one line per failing item — stale date or zero value — with the actual numbers>
Revenue vs. source (60d): <one-line summary from Step 4>
Spend vs. source (60d): <one-line summary from Step 4>
Ref: DMABGS-3270
```

The header carries the state emoji (from the three states above), so no separate "test"
framing is needed — post it as the real check. Only the `FAILURES DETECTED` state needs to
alarm on-call. Keep the message compact; only expand failing items with detail.

## Notes

- This is read-only against Snowflake — it never writes to the warehouse.
- If a check legitimately lags (e.g. a known weekend delay), that will show as a failure;
  mention it in the summary rather than hiding it, so a human can judge.
- Exact SQL lives in `references/queries.sql`; the rotation table in `references/rotation.md`.
  Read those when running — they hold the authoritative task names, column names, and schedule.
