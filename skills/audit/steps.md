# Full sentinel audit

Run the security audit on this repository. Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue.

This session only finds and records. Do not fix code, do not write tests, and do not commit anything. What happens to the findings afterwards is the user's decision.

## Before you start

Check these and stop with a clear message if any is missing:

- `.sentinel/` exists. If not, the repo has not been onboarded: tell the user to run `/snt:onboard` first.
- `audit/` and `CLAUDE-SECURITY-*/` are in `.gitignore`. Add any that are missing, and say so.
- The `claude-security` plugin is installed.

## 1. Mechanical checks

Create `audit/` if it does not exist. Run `.sentinel/mechanical/check.sh .` with its output saved to `audit/check.txt`, and summarize the failures by tool. Do not fix anything.

## 2. Claude Security scan

Before running `/claude-security`, ask the user which scan to run, in one AskUserQuestion. Run `git branch --show-current` first. If it prints `main` or `master`, or nothing, put the release scan first and mark it " (Recommended)"; otherwise do that for the branch scan.

- **Release scan:** the whole repository at `medium`. For the audit before a release.
- **Branch scan:** this branch's committed changes against its base, at `high`. For a feature branch before it merges. Uncommitted work is not scanned.
- **Quick scan:** the whole repository at `low`: one researcher and the verification panel. For a fast check between releases.

Run the `claude-security` skill with the choice spelled out, so it skips its own menu: "scan the whole repository at medium", "scan this branch's changes at high" or "scan the whole repository at low". If the user typed their own answer, pass it on as written. Leave its cost confirmation to the user. If it reports nothing to scan, stop and say so; do not switch to another scan.

When it finishes, find the newest `CLAUDE-SECURITY-<timestamp>/` directory, copy its `CLAUDE-SECURITY-RESULTS.md` to `audit/claude-security.md`, and show the user the findings by severity.

Do not run or offer its suggest-patches job. Patches are fixes, and this audit fixes nothing.

## 3. Findings log

Write one row per step into `audit/findings-log.md`: the date, the repo, the step (for Claude Security, with the scan in brackets, for example `claude-security (branch)`), and what it found (for check.sh, the tools that failed; for Claude Security, the count of findings by severity). Leave the notes column empty for the user. If the file does not exist, start it from `.sentinel/findings-log.md`. Never write into `.sentinel/`: it is the kit's public repository, and the log can count findings that are not fixed yet.

## Finish

Tell the user where everything is: `audit/check.txt`, `audit/claude-security.md`, the `CLAUDE-SECURITY-<timestamp>/` directory and `audit/findings-log.md`. Remind them that nothing was fixed or committed.
