---
name: onboard
description: Onboard the current repository to the sentinel security-audit kit, once per repo - adds the kit as the .sentinel submodule, writes THREAT-MODEL.md from the code, the security-guidance rules, fuzz targets, deny.toml, the fast CI workflow and SECURITY.md, then checks the repo's GitHub settings and adds the release gate, stopping after each step. Run only on an explicit /snt:onboard.
disable-model-invocation: true
---

# Onboard this repo to sentinel

The steps live in the sentinel kit itself, so they always match the files they copy.

1. If `.sentinel/` does not exist, add the kit as a git submodule: `git submodule add https://github.com/jcrenshaw-dev/sentinel .sentinel`. Do not commit it.
2. Read `.sentinel/skills/onboard/steps.md` in full and follow it exactly. Its first step treats an existing `.sentinel/` as already added and covers the rest of setting up the kit.
3. If that file does not exist, the kit is older than this plugin, and in it `.sentinel/skills/onboard/SKILL.md` holds the full steps: read it in full and follow it exactly instead.
