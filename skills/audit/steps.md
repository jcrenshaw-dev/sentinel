# Full sentinel audit

Run the security audit on this repository. Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue.

This session only finds and records. Do not fix code, do not write tests, and do not commit anything. Step 1 runs the project's code: clippy, cargo geiger and the fuzz build compile it, which runs its build scripts and proc macros and those of its dependencies, the fuzz run runs its fuzz targets, and Miri runs its unit tests. The Claude Security scan, the lenses and the check of their findings only read it. What happens to the findings afterwards is the user's decision.

## Before you start

Check these and stop with a clear message if any is missing:

- `.sentinel/` exists. If not, the repo has not been onboarded: tell the user to run `/snt:onboard` first.
- `audit/` and `CLAUDE-SECURITY-*/` are in `.gitignore`. Add any that are missing, and say so.
- The `claude-security` plugin is installed.

## 1. Mechanical checks

Create `audit/` if it does not exist. Run `SENTINEL_FUZZ_SECONDS=${SENTINEL_FUZZ_SECONDS:-60} .sentinel/mechanical/check.sh .` with its output saved to `audit/check.txt`, and summarize the failures by tool. It runs each fuzz target for that many seconds, so it can outlast a tool call's timeout: run it in the background and wait for it to finish. List any fuzz artifact paths it printed, but never open or print an artifact: it is untrusted input. Do not fix anything.

## 2. Claude Security scan

Before running `/claude-security`, ask the user which scan to run, in one AskUserQuestion. Run `git branch --show-current` first. If it prints `main` or `master`, or nothing, put the release scan first and mark it " (Recommended)"; otherwise do that for the branch scan.

- **Release scan:** the whole repository at `medium`. For the audit before a release.
- **Branch scan:** this branch's committed changes against its base, at `high`. For a feature branch before it merges. Uncommitted work is not scanned.
- **Quick scan:** the whole repository at `low`: one researcher and the verification panel. For a fast check between releases.

Run the `claude-security` skill with the choice spelled out, so it skips its own menu: "scan the whole repository at medium", "scan this branch's changes at high" or "scan the whole repository at low". If the user typed their own answer, pass it on as written. Leave its cost confirmation to the user. If it reports nothing to scan, stop and say so; do not switch to another scan.

When it finishes, find the newest `CLAUDE-SECURITY-<timestamp>/` directory, copy its `CLAUDE-SECURITY-RESULTS.md` to `audit/claude-security.md`, and show the user the findings by severity.

After a whole-repository scan, read the report's Coverage section for production files it did not cover: files it says were not assigned to any component, were read only as background, or should not be counted as covered. List every one, and mark any that is test-only code. If there are any, start your report for this step with this line, filled in:

`ALERT: Claude Security did not cover <N> production files: <paths>. This audit is not complete until they are scanned.`

Then offer a scoped scan of exactly those files at the same effort. If the user runs it, copy its report to `audit/claude-security-skipped.md` and log it as its own row, `claude-security (skipped files)`.

Do not run or offer its suggest-patches job. Patches are fixes, and this audit fixes nothing.

## 3. Lens pass

The lenses are eight review prompts in `.sentinel/lenses/`, one concern each, that read the whole repository against `THREAT-MODEL.md`. They find things the Claude Security scan misses, and a second model finds things the first one misses. They cost real money or plan usage, so nothing runs until the user chooses.

Ask the user in one AskUserQuestion whether to run them, and on which model. First check whether `CODEX_API_KEY` or `OPENAI_API_KEY` is set, without printing either, so the question can name the account Codex would bill. Offer exactly these four, with the recommended one first and marked " (Recommended)": Both after a release scan, Claude after a quick scan, Skip after a branch scan (the lenses read the whole repository, not the diff).

- **Claude:** one run of each lens on the logged-in Claude plan. On Terminus (622 tracked files) this took about 35 minutes and came to about $31 at API prices.
- **Codex:** one run of each lens on Codex, billed to the API key, or to the Codex login when no key is set. On Terminus this took about 17 minutes and cost about $35.
- **Both:** the two together.
- **Skip:** run nothing.

Say in the question that the costs come from Terminus and grow with the size of the repository.

If the answer includes Codex and `codex` is not on PATH, say so and stop this step. Otherwise run `.sentinel/lenses.sh . <claude|codex|both>` and wait for it. It prints where the results went, `audit/lenses/<timestamp>/`, and a line for each run, also kept in `run.txt`. The line says `ok`, `FAILED`, `BLOCKED` (a safeguard stopped the reply) or `UNPARSEABLE` (the reply has no finding and no `No findings` block, a refusal for one). A Claude run's line also names the model that answered and says `MODEL DIFFERS` when it is not the one asked for, and an `ok` line names any finding that is missing a field. A run that is not `ok` left no report: show the end of its `.log` and ask before running it again. Never rerun on your own: a failed run can be a spent quota.

On Skip, go straight to step 5 and log `lenses (skipped)`.

## 4. Check the lens findings

Lens output is unverified, and its severities run high. Check it before the user sees it. This step reads only: never build, run or test the code, and never write an exploit or a proof of concept.

1. Read `audit/lenses/<timestamp>/run.txt` and every `## Finding` block in the `<provider>/<lens>.md` reports next to it, then `THREAT-MODEL.md`, `audit/claude-security.md` and, if it exists, `audit/claude-security-skipped.md`.
2. Group findings that describe the same problem, keeping track of which provider and lens reported each. Set aside, with a one-line reason each:
   - those the Claude Security report already has (name its finding),
   - those `THREAT-MODEL.md` already documents (quote the line),
   - those that need something `THREAT-MODEL.md` says is not an escalation, such as a same-user process that can already write the files.
3. Send the rest to read-only subagents, grouped by area, a handful of findings each. Each one reads `THREAT-MODEL.md` first, traces its findings in the code at file:line without trusting the lens's line numbers or claims, and returns for each: CONFIRMED (the whole path traced, every step at file:line), PARTLY (what holds and what doesn't), or NOT CONFIRMED (why); whether `THREAT-MODEL.md` documents it; the severity under the threat model's own rules; and the preconditions. Tell them to read only and to write no files.
4. Write `audit/lenses.md`:
   - first, every run in `run.txt` that is not `ok` or says `MODEL DIFFERS`, so the pass can't look complete when it isn't. A lens with no `ok` run on any provider was not covered;
   - the confirmed and partly confirmed findings by severity, each with its path, the provider and lens that found it, and its preconditions. A finding `run.txt` says is missing a field is checked like the rest, with the missing fields named next to it;
   - the set-aside list with reasons;
   - any line of `THREAT-MODEL.md` the check found to be wrong.

Show the user the confirmed findings by severity.

## 5. Findings log

Write one row per step into `audit/findings-log.md`: the date, the repo, the step (for Claude Security, with the scan in brackets, for example `claude-security (branch)`; for the lenses, with the choice in brackets, for example `lenses (both)` or `lenses (skipped)`), and what it found (for check.sh, the tools that failed; for Claude Security and the lenses, the count of findings by severity, for the lenses after the check). Leave the notes column empty for the user. If the file does not exist, start it from `.sentinel/findings-log.md`. Never write into `.sentinel/`: it is the kit's public repository, and the log can count findings that are not fixed yet.

## Finish

Tell the user where everything is: `audit/check.txt`, `audit/claude-security.md`, `audit/claude-security-skipped.md` if the skipped-files scan ran, the `CLAUDE-SECURITY-<timestamp>/` directory, `audit/lenses.md` and `audit/lenses/<timestamp>/` if the lenses ran, and `audit/findings-log.md`. Remind them that nothing was fixed or committed.
