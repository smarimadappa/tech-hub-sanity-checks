# Releasing plugins in this marketplace

One repo, multiple skills (one plugin per skill), each versioned independently by its own
`plugin.json`. Edit the files here and push — no zipping.

## Files that matter (per plugin, e.g. `d001-sanity-check`)
- `plugins/<plugin>/skills/<plugin>/SKILL.md` — the check logic
- `.../references/queries.sql` — authoritative SQL (task names, columns)
- `.../references/rotation.md` — on-call rotation + Slack IDs (extend before it runs out)
- `plugins/<plugin>/.claude-plugin/plugin.json` — the **`version`** field is the release valve
- `.claude-plugin/marketplace.json` — lists every plugin; add an entry here when adding a new plugin

## To ship a change (every time)
1. Edit the file(s) — by hand, or tell Claude "update the skill to ..." while this folder is open.
2. Bump `version` in that plugin's `plugin.json`:
   - PATCH (0.1.0 -> 0.1.1): wording/typo, no behavior change
   - MINOR (0.1.1 -> 0.2.0): new step/capability, rotation extended, backward-compatible
   - MAJOR (0.2.0 -> 1.0.0): changes the pass/fail logic or output in a surprising way
3. Commit, tag, push. Tags are **per plugin** (`<plugin-name>-v<version>`) since one repo
   now hosts multiple independently-versioned plugins — a bare `vX.Y.Z` tag would collide
   across plugins:
   ```bash
   git add -A
   git commit -m "describe the change"
   git tag d001-sanity-check-v0.2.0
   git push origin main --tags
   ```
4. (Optional pre-flight) `claude plugin validate ./plugins/<plugin>`

Users update via Customize → Plugins (Cowork) or `/plugin marketplace update` (Claude Code).
Push commits WITHOUT bumping `version` and users see nothing — safe for work-in-progress.

## First-time setup for a new user (once)
- Cowork: Customize → Plugins → Add marketplace `smarimadappa/tech-hub-sanity-checks` → Install.
- Claude Code: `/plugin marketplace add smarimadappa/tech-hub-sanity-checks` then
  `/plugin install d001-sanity-check@gdm-skills` (and, after step 3, `/plugin install d000-sanity-check@gdm-skills`).
