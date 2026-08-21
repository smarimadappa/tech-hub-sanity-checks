# Releasing d001-sanity-check

One repo, one skill, versioned by `plugin.json`. Edit the files here and push — no zipping.

## Files that matter
- `plugins/d001-sanity-check/skills/d001-sanity-check/SKILL.md` — the check logic
- `.../references/queries.sql` — authoritative SQL (task names, columns)
- `.../references/rotation.md` — on-call rotation + Slack IDs (extend before it runs out)
- `plugins/d001-sanity-check/.claude-plugin/plugin.json` — the **`version`** field is the release valve

## To ship a change (every time)
1. Edit the file(s) — by hand, or tell Claude "update the skill to ..." while this folder is open.
2. Bump `version` in `plugin.json`:
   - PATCH (0.1.0 -> 0.1.1): wording/typo, no behavior change
   - MINOR (0.1.1 -> 0.2.0): new step/capability, rotation extended, backward-compatible
   - MAJOR (0.2.0 -> 1.0.0): changes the pass/fail logic or output in a surprising way
3. Commit, tag, push:
   ```bash
   git add -A
   git commit -m "describe the change"
   git tag v0.2.0
   git push origin main --tags
   ```
4. (Optional pre-flight) `claude plugin validate ./plugins/d001-sanity-check`

Users update via Customize → Plugins (Cowork) or `/plugin marketplace update` (Claude Code).
Push commits WITHOUT bumping `version` and users see nothing — safe for work-in-progress.

## First-time setup for a new user (once)
- Cowork: Customize → Plugins → Add marketplace `smarimadappa/tech-hub-sanity-checks` → Install.
- Claude Code: `/plugin marketplace add smarimadappa/tech-hub-sanity-checks` then
  `/plugin install d001-sanity-check@gdm-skills` (and, after step 3, `/plugin install d000-sanity-check@gdm-skills`).
