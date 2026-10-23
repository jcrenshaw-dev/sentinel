# Findings log

One row per step of each audit: `check.sh`, `claude-security` with the scan in brackets (`(release)`, `(branch)`, `(quick)` or `(skipped files)`), `lenses` with the choice in brackets (`(claude)`, `(codex)`, `(both)` or `(skipped)`), `check` with the choice in brackets (`(cross-check)` or `(claude)`), and a `threat-model` row when the audit went on with THREAT-MODEL.md out of date. "What it found" is the tools that failed, for check.sh; the count of findings by severity, for Claude Security and the lenses, with how many were new, how many were already known, and how many open findings went unreported; and for the check, how many claims stood, stood in part, were refuted and went unchecked. Each finding's own history is in the findings register, `audit/findings.md`. "Notes" is yours to fill in.

This file in sentinel stays an empty template. `/snt:audit` keeps the filled-in copy for each project at `audit/findings-log.md` in that project, which stays out of git with the rest of `audit/`: a row counts findings, and some of them may not be fixed yet.

| date | repo | step | what it found | notes |
|------|------|------|---------------|-------|
|      |      |      |               |       |
