# GDM data-pipeline sanity checks

A Claude plugin **marketplace** (`gdm-skills`) for the GDM analytics team. Each plugin is a
daily sanity check that verifies a Snowflake pipeline's tasks succeeded and its output data is
fresh, then posts a pass / fail summary to `#sanity-check-testing` (tagging the week's on-call).

All checks are **read-only** against the GDM Snowflake account (`GARTNER_GDM`) and share one
Slack channel and one on-call rotation.

## Plugins in this marketplace

| Plugin | Pipeline | Jira |
|--------|----------|------|
| `d000-sanity-check` | D-000 Channel Dashboard — task + dashboard-slice freshness, revenue reconciliation, shadow-mode anomaly check | DMABGS-3269 |
| `d001-sanity-check` | D-001 Performance Cube — two tasks (cube refresh + MDD) + cube max-date/value freshness | DMABGS-3270 |
| `d009-sanity-check` | D-009 Site Performance — parent + five child tasks + five output-table max dates | — |
| `d033-sanity-check` | D-033 BX Self-Service Tool — delete + insert tasks + output max date and per-brand value | DMABGS-3271 |

Each check runs itself when you ask (e.g. "run the D-001 sanity check", "is site performance
fresh?") or on a scheduled task. Prefer the skill over ad-hoc SQL — it holds the authoritative
task names, columns, and thresholds.

## Install (one-time setup)

You need **read access to this repo** (private) and GitHub authenticated (in Cowork: signed in to
GitHub; in Claude Code: `gh auth login` or an SSH key).

### In Cowork (desktop app)

1. Open **Customize** in the sidebar → **Plugins**.
2. Click **Add marketplace** and enter `smarimadappa/tech-hub-sanity-checks`
   (the `owner/repo` shorthand or the full GitHub URL both work).
3. Find the check you want (e.g. **d001-sanity-check**) in the list and click **Install**.
   Install as many as you need — they're independent.

### In Claude Code (terminal)

```
/plugin marketplace add smarimadappa/tech-hub-sanity-checks
/plugin install d001-sanity-check@gdm-skills
/plugin install d000-sanity-check@gdm-skills
/plugin install d009-sanity-check@gdm-skills
/plugin install d033-sanity-check@gdm-skills
```

Every check requires the GDM **Snowflake** and **Slack** connectors. Each runs best shortly after
its pipeline's tasks land — the skill anchors off the last task run, so a same-day check after the
pipeline finishes is the sweet spot.

## Get the latest version

- **Cowork:** Customize → Plugins → update the plugin.
- **Claude Code:** `/plugin marketplace update`.

## Layout

```
.claude-plugin/marketplace.json      # lists every plugin
plugins/<plugin>/
  .claude-plugin/plugin.json         # name + version (the release valve)
  skills/<plugin>/
    SKILL.md                         # the check logic / runbook
    references/queries.sql           # authoritative SQL (task names, columns)
    references/rotation.md           # on-call rotation + Slack IDs
CHANGELOG.md                         # per-plugin change history
```

## Who maintains this

The GDM team owns these skills. Authoritative SQL and the on-call rotation live under each plugin's
`references/` directory — **extend the rotation table before it runs out**. See `RELEASING.md` for
the release process (versions and tags are **per plugin**).
