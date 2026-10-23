# Full sentinel audit

Run the security audit on this repository. Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue.

This session only finds and records. Do not fix code, do not write tests, and do not commit anything. Step 1 runs the project's code: clippy and the fuzz build compile it, which runs its build scripts and proc macros and those of its dependencies, the fuzz run runs its fuzz targets, and Miri runs its unit tests. The Claude Security scan, the lenses and the check of their findings only read it. What happens to the findings afterwards is the user's decision.

## Before you start

Check these and stop with a clear message if any is missing:

- `.sentinel/` exists. If not, the repo has not been onboarded: tell the user to run `/snt:onboard` first.
- `audit/` and `CLAUDE-SECURITY-*/` are in `.gitignore`. Add any that are missing, and say so.
- The `claude-security` plugin is installed.

Then check that `THREAT-MODEL.md` still describes the code. Every later step judges findings against it. Run `.sentinel/threat-model-age.sh .`:

- Exit 0: it is current. Say so in one line and go on.
- Exit 1: files changed after the commit it names. Read the changed files it lists, and name the production files among them that touch what `THREAT-MODEL.md` covers: what the tool reads, writes or runs, who runs it, and what it must never touch. Leave out tests, docs and planning files. If none are left, say so in one line and go on. Otherwise tell the user the threat model is out of date, with the script's first line and those files, and ask in one AskUserQuestion:
  - **Stop and update it first (Recommended):** the lenses and step 4 judge every finding against it, so a stale one shifts what counts as a finding. End the audit here. It can be updated with `/snt:onboard`'s threat model step or by hand.
  - **Continue with the gap recorded:** go on, and log the gap in step 5.
- Exit 2: there is no commit to compare against. Show its message and ask the same question.

Then, if `audit/findings.md` does not exist but `audit/` already holds reports from earlier audits (`claude-security*.md`, `lenses.md` or other findings reports), start the register now, before step 2 overwrites any of them. Copy `.sentinel/findings-register.md` to `audit/findings.md` and enter every finding those reports hold, as described in step 5, with the report's date as first and last seen. Use the repo's directory name for `<repo>` in the IDs. Count findings that describe the same defect once. Say how many you entered.

## 1. Mechanical checks

Create `audit/` if it does not exist, with `mkdir -m 700 audit`: it holds unfixed findings, so no other user on the machine gets to read it.

If the repo has fuzz targets, ask how to fuzz first, in one AskUserQuestion. Count the targets as the `.rs` files under any `fuzz/fuzz_targets/` folder, outside `target/`. Work out how many can run at once: the smallest of the target count, the core count from `nproc`, and the available memory in GB from `free -g` divided by 2, since libFuzzer can use 2 GB per target. Fill the real numbers into the options:

- **Smoke test (Recommended):** 60 seconds per target, one at a time, about <targets> minutes. For a normal audit.
- **Long run:** 30 minutes per target, <at once> at a time, about <30 × the number of rounds it takes> minutes, using <at once> cores. For before a release. Each run starts from the inputs earlier runs found, so long runs add up.
- **Skip fuzzing:** step 1 runs every other check, the fuzz build included.

Then run `.sentinel/mechanical/check.sh .` with its output saved to `audit/check.txt`, set for the answer: `SENTINEL_FUZZ_SECONDS=60 SENTINEL_FUZZ_JOBS=1` for the smoke test, `SENTINEL_FUZZ_SECONDS=1800 SENTINEL_FUZZ_JOBS=<at once>` for the long run, and `env -u SENTINEL_FUZZ_SECONDS` for skip. Without fuzz targets, run it with no settings. Summarize the failures by tool. For Miri, a test that stopped on `Undefined Behavior` is a finding. A test that stopped on `unsupported operation` hit something Miri cannot run, such as a call into C or starting a process, and a test that timed out did not finish. Give those two as counts, not as failures. List any other failing test by name. With fuzzing it can outlast a tool call's timeout: run it in the background and wait for it to finish. List any fuzz artifact paths it printed, but never open or print an artifact: it is untrusted input. Do not fix anything.

## 2. Claude Security scan

Before running `/claude-security`, ask the user which scan to run, in one AskUserQuestion. Run `git branch --show-current` first. If it prints `main` or `master`, or nothing, put the release scan first and mark it " (Recommended)"; otherwise do that for the branch scan.

- **Release scan:** the whole repository at `medium`. For the audit before a release.
- **Branch scan:** this branch's committed changes against its base, at `high`. For a feature branch before it merges. Uncommitted work is not scanned.
- **Quick scan:** the whole repository at `low`: one researcher and the verification panel. For a fast check between releases.

Run the `claude-security` skill with the choice spelled out, so it skips its own menu: "scan the whole repository at medium", "scan this branch's changes at high" or "scan the whole repository at low". If the user typed their own answer, pass it on as written. Leave its cost confirmation to the user. If it reports nothing to scan, stop and say so; do not switch to another scan.

When it finishes, find the newest `CLAUDE-SECURITY-<timestamp>/` directory, copy its `CLAUDE-SECURITY-RESULTS.md` to `audit/claude-security.md`, and show the user the findings by severity. A finding that is the same defect as a row in `audit/findings.md` with status `accepted`, judged as in step 5, is left out of that list and shown only as a count, such as "2 accepted findings came back".

After a whole-repository scan, read the report's Coverage section for production files it did not cover: files it says were not assigned to any component, were read only as background, or should not be counted as covered. List every one, and mark any that is test-only code. If there are any, start your report for this step with this line, filled in:

`ALERT: Claude Security did not cover <N> production files: <paths>. This audit is not complete until they are scanned.`

Then offer a scoped scan of exactly those files at the same effort. If the user runs it, copy its report to `audit/claude-security-skipped.md` and log it as its own row, `claude-security (skipped files)`.

Do not run or offer its suggest-patches job. Patches are fixes, and this audit fixes nothing.

## 3. Lens pass

The lenses are eight review prompts in `.sentinel/lenses/`, one concern each, that read the whole repository against `THREAT-MODEL.md`. They find things the Claude Security scan misses, and a second model finds things the first one misses. They cost real money or plan usage, so nothing runs until the user chooses.

Ask the user in one AskUserQuestion whether to run them, and on which model. First check whether `SENTINEL_ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY` is set, and whether `CODEX_API_KEY` or `OPENAI_API_KEY` is set, without printing any of them, so the question can name the account each provider would bill. Offer exactly these four, with the recommended one first and marked " (Recommended)": Both after a release scan, Claude after a quick scan, Skip after a branch scan (the lenses read the whole repository, not the diff).

- **Claude:** one run of each lens, billed to the API key when `SENTINEL_ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY` is set (name which), or to the logged-in Claude plan when neither is. On Terminus (622 tracked files) this took about 35 minutes and came to about $31 at API prices.
- **Codex:** one run of each lens on Codex, billed to the API key, or to the Codex login when no key is set. On Terminus this took about 17 minutes and cost about $35.
- **Both:** the two together.
- **Skip:** run nothing.

Say in the question that the costs come from Terminus and grow with the size of the repository.

If the answer includes Codex and `codex` is not on PATH, say so and stop this step. Otherwise run `.sentinel/lenses.sh . <claude|codex|both>` and wait for it. It prints where the results went, `audit/lenses/<timestamp>/`, and a line for each run, also kept in `run.txt`. The line says `ok`, `FAILED`, `BLOCKED` (the reply ended in a refusal) or `UNPARSEABLE` (the reply has no finding and no `No findings` block, a refusal for one). A Claude run's line also names the model that answered and says `MODEL DIFFERS` when it is not the one asked for, and `SAFETY STOP during the run` when a safeguard stopped one of its replies but the run went on to a complete report, which is kept, and an `ok` line names any finding that is missing a field and how many of the snapshot's files the run read in full. It also writes `coverage.txt`: the files no run with a report read, then those read only in part, then every file with the runs that read it. A file counts only when its contents reached the model. A run that is not `ok` left no report: show the end of its `.log` and ask before running it again. Never rerun on your own: a failed run can be a spent quota. To rerun one lens, run `SENTINEL_LENSES=<lens> .sentinel/lenses.sh . <provider>`, with several names comma separated; it writes a new `audit/lenses/<timestamp>/` folder, which step 4 reads alongside the first.

On Skip, go straight to step 5 and log `lenses (skipped)`.

## 4. Check the lens findings

Lens output is unverified, and its severities run high. Check it before the user sees it. This step reads only: never build, run or test the code, and never write an exploit or a proof of concept.

1. Read `run.txt` and every `## Finding` block in the `<provider>/<lens>.md` reports in each `audit/lenses/<timestamp>/` folder this audit made, the full pass and any rerun of single lenses; a rerun's `ok` report stands in for that lens's failed run. Then `THREAT-MODEL.md`, `audit/claude-security.md` and, if it exists, `audit/claude-security-skipped.md`.
2. Check that some reviewer looked at every production file. The lenses are targeted, so they read only part of the repository; the Claude Security scan is the one meant to read it all. Read the "Read by no run" and "Read only in part" lists in each folder's `coverage.txt`; a file counts as read in full when any folder's `coverage.txt` lists it under "Read in full by". Mark each file that no folder lists as read in full as production code, test-only, or not code (docs, data, lock files, images). Then take the production files Claude Security did not cover: after a whole-repository scan, the files step 2 listed from its Coverage section, less any the skipped-files scan covered; after a branch scan, every file outside the branch's diff. The files on both lists were read by no reviewer. If there are any, start `audit/lenses.md` and your report for this step with this line, filled in:

   `ALERT: no reviewer read <N> production files: <paths>. Neither Claude Security nor the lenses covered them. This audit is not complete until they are reviewed.`
3. Group findings that describe the same problem, keeping track of which provider and lens reported each. Set aside, with a one-line reason each:
   - those the Claude Security report already has (name its finding),
   - those `THREAT-MODEL.md` already documents (quote the line),
   - those that need something `THREAT-MODEL.md` says is not an escalation, such as a same-user process that can already write the files,
   - those that are the same defect as a row in `audit/findings.md` with status `accepted`, judged as in step 5 (give its ID and the user's reason). Step 5 still updates that row's last seen. Report them only as a count, such as "3 accepted findings came back".
4. Write the rest as claims files, for `.sentinel/refute.sh` to send to the other model family. Add every Claude Security finding from this audit as claims too: its own verifiers are Claude, and this is its one look from outside. Make groups by area, a handful of claims each, and keep the two families apart: a group holds either findings Codex reported, including any Claude reported as well, or findings only Claude reported (a Claude lens or Claude Security). Write each group to `audit/claims/<area>.md` (`mkdir -p -m 700 audit/claims` first), with a number after the area when it has more than one group, and no word of the family in the name. In each file, number the claims from 1 and write each one in your own words:

   ```
   ## Claim 1
   - location: <path:line>
   - trigger: <the input or sequence that makes it happen>
   - consequence: <what the attacker or the bug gets>
   ```

   Never put in a claim which provider or lens reported it, what severity it was given, or what any other check concluded.
5. Ask the user in one AskUserQuestion how to check, unless `codex` is not on PATH: then everything goes to Claude, and you say so.
   - **Cross-check (Recommended):** the groups Codex reported go to Claude, the groups only Claude reported go to Codex, so every finding is checked by a different model family than found it. Codex is billed to the key or the Codex login, Claude to the key or the plan, as in step 3.
   - **Claude only:** every group goes to Claude. `audit/lenses.md` and `SENTINEL.md` then say the findings were checked by the same family that found them.
6. Run `.sentinel/refute.sh . codex audit/claims/<file>...` for the groups that go to Codex and `.sentinel/refute.sh . claude audit/claims/<file>...` for the groups that go to Claude, and wait for each. Each run reads `THREAT-MODEL.md` first, then tries to prove each claim wrong in the same sandbox the lenses run in, and answers for each: REFUTED (what stops it, at file:line), PARTLY (what holds and what is refuted, each at file:line) or STANDS (it could not be refuted, the whole path traced, every step at file:line); whether `THREAT-MODEL.md` documents it; the severity under the threat model's own rules; and the preconditions. It prints where the verdicts went, `audit/refute/<timestamp>/`, and a line for each run, also kept in its `run.txt`, in the same shape as the lens runs: `ok`, `FAILED`, `BLOCKED` or `UNPARSEABLE`, with `MODEL DIFFERS` and `SAFETY STOP` notes for Claude. An `ok` line can also say `claim N is missing` or `has no verdict`. A claim in a run that is not `ok`, or named in such a note, is unchecked: show the end of the `.log` and ask before running that file again. Never rerun on your own.
7. Write `audit/lenses.md`:
   - the ALERT line, if there is one, then one line of what the lenses read, such as "The lenses read 48 of 435 files in full and 31 in part; the full lists are in `coverage.txt`." Don't list the files the lenses alone did not read;
   - one line saying who checked: "Checked by Codex for the findings Claude reported and by Claude for the findings Codex reported" or "Checked by Claude for every finding, the same family that reported them";
   - every lens run in `run.txt` that is not `ok`, says `MODEL DIFFERS`, or says `SAFETY STOP during the run`, so the pass can't look complete when it isn't. A safety stop means part of that lens's work may be missing from its report. A lens with no `ok` run on any provider was not covered;
   - the findings that stand or partly stand, by the severity the check gave them, each with its path, the provider and lens that found it, the family that checked it, and its preconditions. For a finding that partly stands, say what was refuted. A finding `run.txt` says is missing a field is checked like the rest, with the missing fields named next to it;
   - the refuted findings, each with what stops it at file:line and the family that refuted it;
   - the unchecked findings, with the run or note that left them unchecked;
   - the set-aside list with reasons;
   - any line of `THREAT-MODEL.md` the check found to be wrong.

Show the user the findings that stand or partly stand, by severity, and the unchecked ones.

## 5. Findings register and log

Every finding gets an ID that stays the same from audit to audit, kept in `audit/findings.md`. If the file does not exist, start it from `.sentinel/findings-register.md`.

1. Take every Claude Security finding from this audit, including the skipped-files scan, every lens finding that stands or partly stands after step 4, every lens finding step 4 left unchecked, and every lens finding step 4 set aside as accepted. For each, decide whether it is the same defect as a row in the register: the same flaw in the same code, judged by reading the code at both locations, not by matching line numbers or titles. A finding that matches keeps that row's ID: set last seen to today, update its severity and location, and add this step to found by. A finding that matches nothing gets the next unused ID, `<repo>-NNN`, numbered after the highest in the file, with today as first and last seen and status `open`. A Claude Security finding keeps Claude Security's severity, and its step 4 verdict goes in its notes, such as `check: REFUTED by codex, <what stops it>`; an unchecked finding gets `unchecked <today>`.
2. For every `open` row this audit did not report, add `not reported <today>` to its notes. If `git log` shows commits touching its file since it was last seen, add `check whether fixed`. Never set a status yourself: `fixed` and `accepted` are the user's.
3. Put each finding's ID next to it in `audit/lenses.md`, and use the IDs whenever you show the user findings from now on.

Then write one row per step into `audit/findings-log.md`: the date, the repo, the step (for Claude Security, with the scan in brackets, for example `claude-security (branch)`; for the lenses, with the choice in brackets, for example `lenses (both)` or `lenses (skipped)`), and what it found (for check.sh, the tools that failed; for Claude Security and the lenses, the count of findings by severity, for the lenses after the check, followed by how many were new, how many were already in the register, and how many open findings this audit did not report). When the threat model was out of date and the user chose to continue, add a `threat-model` row with the script's first line and the count of production files you named. Leave the notes column empty for the user. If the file does not exist, start it from `.sentinel/findings-log.md`. Never write into `.sentinel/`: it is the kit's public repository, and the log can count findings that are not fixed yet.

Then write the stamp: `SENTINEL.md` at the repo root, from everything below the `---` line in `.sentinel/stamp.md`. It is the one file the audit writes outside `audit/`, and the one meant to be committed, so it holds counts and nothing a finding could be found from: never a title, a location, a fingerprint or a line of code. Fill every `<...>` from this audit: the date, the commit (`git rev-parse --short HEAD`), the sentinel commit (`git -C .sentinel rev-parse --short HEAD`), the threat model line from the check before step 1, step 1's summary block in `audit/check.txt`, the scan and its coverage from step 2, `run.txt` and `coverage.txt` from step 3, the counts from step 4, and the open and accepted counts from the register's status column. Keep the last section word for word, choosing the one marked line by who did the checking in step 4. If `SENTINEL.md` exists, overwrite it: it describes the last audit only. Show it to the user. Never commit it; it is theirs to commit.

## Finish

Tell the user where everything is: `audit/check.txt`, `audit/claude-security.md`, `audit/claude-security-skipped.md` if the skipped-files scan ran, the `CLAUDE-SECURITY-<timestamp>/` directory, `audit/lenses.md` and `audit/lenses/<timestamp>/` if the lenses ran, `audit/findings.md`, `audit/findings-log.md`, and `SENTINEL.md` at the root. Remind them that nothing was fixed or committed, and that `SENTINEL.md` is the one file from this audit meant to be committed.
