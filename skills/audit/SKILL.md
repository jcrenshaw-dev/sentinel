---
name: audit
description: Run the sentinel security audit on the current repository - the mechanical checks, a /claude-security scan, an optional lens pass on Claude or Codex, a check of every finding by the other model family, the findings register and log, and SENTINEL.md, the record of the audit - stopping after each step. Finds and records only; it fixes nothing, writes no tests and commits nothing. Run only on an explicit /snt:audit.
disable-model-invocation: true
---

# Full sentinel audit

The steps live in the sentinel kit this repository is pinned to, so they always match the scripts they call.

1. If `.sentinel/` does not exist, the repo has not been onboarded: tell the user to run `/snt:onboard` first, and stop.
2. Read `.sentinel/skills/audit/steps.md` in full and follow it exactly.
3. If that file does not exist, the pin is older than this plugin, and at that pin `.sentinel/skills/audit/SKILL.md` holds the full steps: read it in full and follow it exactly instead.
