# D-001 Sanity Check — skill

Daily sanity check for the **D-001 Performance Cube** pipeline (Jira DMABGS-3270):
verifies the two Snowflake tasks succeeded and the cube's max dates are fresh, then posts
a pass / fail summary to `#sanity-check-testing`. Distributed as a Claude plugin from this repo.

## Use it (one-time setup)

You need **read access to this repo** first (private), and GitHub authenticated
(in Cowork: signed in to GitHub; in Claude Code: `gh auth login` or an SSH key).

### In Cowork (desktop app)

1. Open **Customize** in the sidebar → **Plugins**.
2. Click **Add marketplace** and enter `smarimadappa/d001-sanity-marketplace`
   (the `owner/repo` shorthand or the full GitHub URL both work).
3. Find **d001-sanity-check** in the list and click **Install**.

### In Claude Code (terminal)

```
/plugin marketplace add smarimadappa/d001-sanity-marketplace
/plugin install d001-sanity-check@gdm-skills
```

Requires the GDM **Snowflake** and **Slack** connectors. The skill runs best on the
~19:15 IST schedule (after the cube refresh and MDD tasks land).

## Get the latest version

- **Cowork:** Customize → Plugins → update d001-sanity-check.
- **Claude Code:** `/plugin marketplace update`.

## Who maintains this

The GDM team owns the skill. Authoritative SQL lives in
`plugins/d001-sanity-check/skills/d001-sanity-check/references/queries.sql`; the on-call
rotation and Slack IDs in `references/rotation.md` (extend the rotation table before it
runs out). See `RELEASING.md` for the release process.
