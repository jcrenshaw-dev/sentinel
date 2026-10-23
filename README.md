# sentinel

sentinel is plain files and bash, with a few Python one-liners that use only the standard library, packaged as a Claude Code plugin so the whole pipeline runs from one command. It is tuned for Rust command-line tools, hooks and MCP servers that work with Claude Code transcripts, and it also covers Node and Python projects.

## Status

sentinel is the audit kit I run on my own tools. It is public so the approach can be read, and it is MIT-licensed, so copy anything useful. It is not packaged or supported for anyone else to depend on: paths, defaults and prompts change whenever my own projects need them to, and I don't take issues or pull requests.

## Using it

Install the plugin once:

```sh
claude plugin marketplace add jcrenshaw-dev/sentinel
claude plugin install snt@sentinel
```

Then, in a project:

- `/snt:onboard` sets the repo up, once. It adds the kit as a git submodule at `.sentinel`, writes `THREAT-MODEL.md` from the code, the security-guidance rules, fuzz targets and `deny.toml` for Rust, the fast CI workflow and `SECURITY.md`. On GitHub it then checks the repository's settings, who can open pull requests, the rulesets on `main` and on tags, secret scanning, Dependabot, and gives you the command for each one that is missing; and it adds the release gate to the release workflow. It stops after each step for you to look, and it does not run the audit.
- `/snt:audit` runs the audit below, stopping after each step. It finds and records; it does not fix, write tests or commit anything.

Each project runs the sentinel version its `.sentinel` submodule is pinned to. Updating a step or a script happens once here, and a project picks it up by moving its pin.

## The audit

What `/snt:audit` runs, in order:

0. **Threat model age.** `.sentinel/threat-model-age.sh .` compares the commit `THREAT-MODEL.md` names with the working tree and lists the files changed since, uncommitted and untracked ones included. If production files it covers changed, the audit stops and asks whether to update it first or continue with the gap logged, because every later step judges findings against it.

1. **Mechanical checks.** `.sentinel/mechanical/check.sh .`, with the output saved to `audit/check.txt`. If the repo has fuzz targets, the audit asks first how to fuzz: a smoke test of 60 seconds per target, one at a time; a long run of 30 minutes per target, as many at once as the machine's cores and memory allow; or no fuzzing.
2. **Claude Security scan.** `/claude-security`, a release, branch or quick scan, picked when the step starts. Its report is copied to `audit/claude-security.md`. After a whole-repository scan, any production file the scan did not cover is flagged with an ALERT, and a scoped scan of those files is offered. Its suggest-patches job is never run.
3. **Lens pass.** Eight review prompts, one concern each, run once each on Claude, on Codex, on both, or skipped. You choose each time, and the question states the cost. `.sentinel/lenses.sh` runs them.
4. **Check.** Every lens finding `THREAT-MODEL.md` doesn't already cover, and every Claude Security finding, goes to the other model family as a neutral claim, with no word of which model or lens found it or what severity it was given: what Claude found goes to Codex and what Codex found goes to Claude, through `.sentinel/refute.sh`, in the same sandbox the lenses run in. Each run tries to prove its claims wrong, and only the ones that stand, traced at file:line, reach `audit/lenses.md` with the severity the check gave them. Without Codex on the machine, or if you choose it, Claude checks everything, and `audit/lenses.md` and `SENTINEL.md` say the findings were checked by the same family that found them.
5. **Findings register and log.** Every finding gets an ID, `<repo>-NNN`, that stays the same from audit to audit, in `audit/findings.md`. A finding that matches a known one, judged by the code and not by line numbers, keeps its ID. Open findings an audit doesn't report get a note, never a status: only you mark a finding `fixed` or `accepted`. A finding you've marked `accepted` that comes back is left out of what the audit shows you and counted instead. If you accepted it because it's by design, saying so in `THREAT-MODEL.md` also stops the lenses and the pull request review from raising it. One row per step goes in `audit/findings-log.md`, with counts of new, known and unreported findings. Then it writes `SENTINEL.md` at the repo root from `stamp.md`: what ran, how each step went, and the open findings as counts by severity, with no locations. It describes the last audit only, and you commit it.

Everything the audit writes goes under `audit/`, apart from Claude Security's own `CLAUDE-SECURITY-<timestamp>/` folder and `SENTINEL.md`. `/snt:onboard` puts the first two in `.gitignore`, because they hold unfixed vulnerability findings. `SENTINEL.md` holds counts and nothing a finding could be found from, and it is meant to be committed.

## The stamp

`SENTINEL.md` is the one thing an audit leaves in the repository for a user to read. The audit writes it and you commit it. It says the date, the commit it covered, the sentinel commit, how current `THREAT-MODEL.md` was, what each step ran and how it went, whether every production file was read by at least one reviewer, and the open and accepted findings as counts by severity. It never holds a finding's title or location: an open finding stays private until it is fixed. It ends with what the record does not say. The audit builds the code, runs its fuzz targets and its unit tests under Miri, and reads the rest; nobody attacked the running program or wrote an exploit, the reviewers are models and miss things, and it names which checks were done by the same model family that made the finding.

`stamp-age.sh` says how far a repository has moved since the commit `SENTINEL.md` names:

```
.sentinel/stamp-age.sh .
```

It prints that commit, how many commits HEAD is ahead of it, and the files changed since, uncommitted and untracked ones included. It exits 1 when any file but `SENTINEL.md` changed, and 2 when there is no `SENTINEL.md` or it names no commit in the repo. As a job in a release workflow, it stops a release the last audit did not cover, and a release with no audit record at all. `/snt:onboard` adds it when the repo has a release workflow:

```yaml
  audited:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          submodules: recursive
          # The audited commit has to be in the history.
          fetch-depth: 0
          persist-credentials: false
      - name: The last audit covers this release
        run: .sentinel/stamp-age.sh .
```

Give the jobs that build or publish `needs: audited`. It cannot tell a production file from a document, so a docs-only change since the audit fails it too. When that happens, either tag the release from the audited commit or run `/snt:audit` again and commit the new `SENTINEL.md`.

## What is in it

| Path | What it is |
|------|------------|
| `.claude-plugin/`, `skills/` | The `snt` plugin: the `onboard` and `audit` skills, and the marketplace entry that installs them. |
| `threat-model.template.md` | The template for a project's `THREAT-MODEL.md`. The pull request review reads it first, and `/snt:onboard` copies its key points into the security-guidance rules. |
| `lenses/*.md` | Eight review prompts, one concern each: data exposure, path handling, untrusted input, permissions, resource limits, hook execution, supply chain, crypto and state. |
| `lenses.sh` | Runs every lens once through `claude -p`, `codex exec` or both. |
| `refute.sh`, `refute.md` | Sends files of neutral claims to Claude or Codex, in the lenses' sandbox, to be proved wrong; `refute.md` is the instructions and the verdict format. Step 4 of the audit runs it. |
| `reviewers.sh` | The snapshot, the two sandboxes and the two reviewers, shared by `lenses.sh` and `refute.sh`. Sourced, not run. |
| `lens-events.py` | Reads the lens runs' JSON events for `lenses.sh`: each Claude run's reply, model and safeguard stops, and which files each run read, for `coverage.txt`. |
| `threat-model-age.sh` | Says how far `THREAT-MODEL.md` is behind HEAD, and which files changed since the commit it names. |
| `stamp.md` | The template for a project's `SENTINEL.md`, the record of its last audit, which `/snt:audit` fills at the end of step 5. |
| `stamp-age.sh` | Says which files changed since the commit `SENTINEL.md` names, and exits 1 when any did. The release gate. |
| `finding-format.md` | The format the pull request review and the lenses write their findings in. |
| `skills/<name>/steps.md` | The steps of `/snt:audit` and `/snt:onboard`. The plugin's skills are short stubs that read these from the project's `.sentinel`, so the steps always match the pinned kit. |
| `mechanical/check.sh` | Runs cargo audit, cargo deny, clippy, semgrep and the rest, depending on what the repo contains. |
| `mechanical/install.sh` | Installs those tools on Arch Linux. |
| `mechanical/deny.toml` | cargo-deny baseline. A repo's own `deny.toml` takes precedence. |
| `mechanical/semgrep.yml` | The semgrep rulesets check.sh runs, and the rules it skips. |
| `ci/fast.yml` | The pull request, push-to-main and weekly workflow for GitHub Actions and Forgejo Actions. |
| `ci/ruleset-main.json`, `ci/ruleset-tags.json` | The GitHub rulesets `/snt:onboard` asks you to create: a pull request with the `mechanical` and `security-review` checks green for every change to `main`, and no deleting or moving tags. |
| `ci/dependabot.yml` | The Dependabot template `/snt:onboard` copies to `.github/dependabot.yml`, trimmed to the ecosystems the repo has: weekly, grouped patches, a seven-day wait on each new version, and the `.sentinel` pin among them. |
| `ci/install-tools.sh` | Installs the mechanical tools on a Debian or Ubuntu CI runner. |
| `ci/security-review.sh`, `ci/security-review.md` | The pull request review `fast.yml` runs, and its prompt. |
| `ci/read-review.sh` | Decrypts a pull request's private review on your machine. |
| `findings-log.md` | The template for a project's `audit/findings-log.md`. |
| `findings-register.md` | The template for a project's `audit/findings.md`, every finding under its stable ID. |

## Requirements

- `bash`, `git`, `python3`.
- Claude Code, with the `claude-security` and `security-guidance` plugins from `claude-plugins-official`.
- The mechanical tools: `mechanical/install.sh` on Arch, `ci/install-tools.sh` on CI runners.
- For a lens pass on Codex: the Codex CLI (`codex`) on PATH, and an OpenAI API key or a Codex login.

## check.sh

Gates fail the run when they fail or when the tool is not installed. Everything else is reported and never fails the run.

| Check | Runs when | Kind |
|-------|-----------|------|
| `cargo audit` | `Cargo.toml` exists | gate |
| `cargo deny check` | `Cargo.toml` exists | gate |
| `cargo clippy --all-targets -- -W clippy::pedantic -W clippy::nursery` | `Cargo.toml` exists | gate (fails on errors and deny-level lints; pedantic and nursery only warn) |
| `semgrep --test` on the repo's own rules in `.semgrep/` (see below) | `.semgrep/` holds at least one rule file | gate |
| `semgrep scan --error` with the rulesets in `semgrep.yml` and the repo's rules in `.semgrep/` | always | gate |
| `cargo geiger`, once per workspace member | `Cargo.toml` exists | report |
| `cargo vet --locked` | `supply-chain/` exists | report |
| `cargo +nightly fuzz build` | a `fuzz/` directory at the root or in any workspace member | report |
| `cargo +nightly fuzz run` on each target `cargo fuzz list` names, for `SENTINEL_FUZZ_SECONDS` seconds each, `SENTINEL_FUZZ_JOBS` targets at a time (default 1). It shows only the lines that say what happened and the path of each new artifact, never the crashing input. | a `fuzz/` directory, and `SENTINEL_FUZZ_SECONDS` set (`/snt:audit` sets both from the answer to its fuzzing question; CI sets neither) | report |
| `cargo +nightly miri nextest run --workspace --lib --bins --no-fail-fast` with isolation off (unit tests only). nextest runs each test in its own Miri process, so a test that calls into C or starts a process, which Miri cannot run, stops only itself. Each test is stopped after 5 minutes (`miri-nextest.toml`). | the repo's own Rust code has an `unsafe` block, fn, impl, trait or extern, and nightly has Miri installed (CI runners skip it) | report |
| Findings stay out of git: fails when any file under `audit/` or `CLAUDE-SECURITY-*/` is tracked, printing the names only. | the repo is a git checkout | gate |
| `gitleaks git --redact` over every commit on every ref. It shows only each finding's fingerprint (`commit:file:rule:line`), never the secret or the line it is on. | the repo is a git checkout | report |
| `diff` of the repo's `fast.yml` against the kit's `ci/fast.yml`, so a copy that has drifted, or a kit whose pins are behind the copy's, shows. | a tracked `.github/workflows/fast.yml` or `.forgejo/workflows/fast.yml` | report |
| `shellcheck -S warning` (errors and warnings, no style notes) on the tracked files named `*.sh` or `*.bash` and the tracked files whose first line runs `sh` or `bash`. zsh scripts are left out, since shellcheck can't read zsh. | the repo is a git checkout with at least one such script | report |
| `zizmor --offline` on the tracked workflows in `.github/workflows/` and `.forgejo/workflows/`, every tracked `action.yml`, and `.github/dependabot.yml`. Offline, it makes no network calls and uses no GitHub token, so it skips the audits that need GitHub's API, such as known-vulnerable action versions. | the repo has at least one such tracked file | report |
| `npm audit` | `package.json` and `package-lock.json` exist | report |
| `pip-audit -r requirements.txt` and `pip-audit .`, one run for each that applies | `requirements.txt`, and `pyproject.toml` with a `[project]` table | report |
| `bandit -r .` | `pyproject.toml` or `requirements.txt` exists | report |

Each fuzz run starts from the inputs earlier runs found, which cargo fuzz keeps in `fuzz/corpus/`, so long runs add up. Each target can use up to libFuzzer's default memory limit of 2 GB, which is why the audit's long run never runs more targets at once than your memory in GB divided by 2, or your core count. Run outside the audit, check.sh takes the same two settings, for example `SENTINEL_FUZZ_SECONDS=1800 SENTINEL_FUZZ_JOBS=13 .sentinel/mechanical/check.sh .`.

shellcheck and zizmor get only tracked regular files that resolve inside the repo, never a symlink. Both print the lines they complain about, so a symlink posing as a script or workflow could otherwise put a file from elsewhere, a key or `/proc/self/environ`, into the output, and on CI into a public log.

semgrep runs with `--metrics=off`. `semgrep.yml` also lists rules to skip: the three p/rust rules that flag reading the program's arguments or its own path (`args`, `args-os`, `current-exe`), which fire on every command-line tool.

### Keeping a fixed finding fixed

When you fix a finding whose bug has a shape a pattern can match, add a semgrep rule for it in the repo's `.semgrep/` folder, in the same commit as the fix. check.sh then runs it with the kit's rulesets, so CI blocks that bug from coming back, with no model involved.

Each rule file (`<name>.yaml`, a top-level `rules:` list) needs a test file next to it with the same name and the target language's extension, such as `<name>.rs`. The test file holds the pre-fix code under a `// ruleid: <rule id>` comment and the fixed code under `// ok: <rule id>`. check.sh runs `semgrep --test` on `.semgrep/` before the scan and fails the gate when a rule misses its own bug, flags the fixed code, or has no test file. `.semgrep/` is left out of the scan itself, so the pre-fix code in a test file doesn't fail it. Only tracked regular files count, never a symlink.

Write the rule for the one bug, not the general idea. A rule that flags every `format!` passed to SQL, say, fails on all the safe ones too.

## lenses.sh

```
lenses.sh <repo-dir> <claude|codex|both>
```

Each lens runs once on each provider you name. Claude runs three lenses at a time and Codex four, and with `both` Claude finishes before Codex starts. Results go to `<repo>/audit/lenses/<timestamp>/<provider>/<lens>.md`, each with a `.log`, plus `run.txt` recording the commit, how current `THREAT-MODEL.md` and `SENTINEL.md` were, models, settings and each run's status. A run that fails, ends in a refusal (`BLOCKED`), or doesn't read as a report (`UNPARSEABLE`: no `## Finding` block and no `## No findings` block listing what it examined) leaves only its `.log`, so a refusal never counts as a clean result. Claude runs record the model that answered and say `MODEL DIFFERS` when it isn't the one asked for. When a safeguard stops one reply and the run still ends with a readable report, the report is kept and the line says `SAFETY STOP during the run`, since part of that lens's work may be missing. Codex's output doesn't name its model, so Codex runs get only the format check. `coverage.txt` lists the files in the snapshot that no run with a report read, then those read only in part, then every file with the runs that read it. A file counts only when its contents reached the model. For Claude that's a Read call that didn't return an error, and the lines it returned decide whether the read was full or partial. For Codex it's a snapshot path given to a command that prints file contents (`cat`, `nl`, `sed`, `head`, `grep`, `rg` and the like), in a command that exited 0, with output that wasn't redirected or piped into something that doesn't print it, like `wc`. Anything `lens-events.py` can't account for doesn't count. The lenses are targeted, so they read only part of a repository, and the Claude Security scan is the one meant to read it all. `/snt:audit` raises an alert only for production files that neither the lenses nor Claude Security covered.

Settings, set as environment variables:

| Variable | Default | What it sets |
|----------|---------|--------------|
| `SENTINEL_MODEL` | `opus` | Claude model (`--model`) |
| `SENTINEL_EFFORT` | `xhigh` | Claude effort (`--effort`) |
| `SENTINEL_CODEX_MODEL` | `gpt-6-astra` | Codex model (`-m`); set it to an empty string for Codex's own default |
| `SENTINEL_CODEX_EFFORT` | `xhigh` | Codex `model_reasoning_effort` |
| `SENTINEL_RUN_TIMEOUT` | `3600` | Seconds before a single run is killed |

Billing: Claude runs in `--safe-mode` on your logged-in claude.ai plan. To bill an API key instead, set `SENTINEL_ANTHROPIC_API_KEY`, or `ANTHROPIC_API_KEY`. Don't export `ANTHROPIC_API_KEY` on a workstation: every interactive Claude Code session would see it alongside your claude.ai login. Codex uses `CODEX_API_KEY`, or `OPENAI_API_KEY` passed to it as `CODEX_API_KEY`, and falls back to your Codex login when neither is set. On Terminus (622 tracked files), one pass cost about $31 at API prices on Claude and about $35 on Codex. The token counts Codex prints in its logs undercount what OpenAI bills, so read the cost from OpenAI's usage page.

What the reviewers can and cannot do:

- They read a snapshot of the repo's tracked and untracked-but-not-ignored files in a private temp directory, so no run sees another run's output and nothing they do touches your working tree. `audit/`, `CLAUDE-SECURITY-*/` and the sentinel directory are left out of the snapshot, so the lenses never see the Claude Security report. Symlinks are left out too, because one could point a reviewer at a file outside the snapshot, and `run.txt` lists each one.
- Claude gets only the Read, Grep and Glob tools, with nothing pre-approved, so any read or search outside the snapshot (your home directory, `/proc`) is refused. (`--bare` would drop Grep and Glob on Linux, which is why the runs use `--safe-mode`.) No settings file is loaded, neither the repo's `.claude/settings.json` nor your own, so an allow rule in your settings can't widen what a reviewer reads. The repo's hooks and MCP servers are not loaded, and neither are your own hooks, plugins, MCP servers or CLAUDE.md. Sessions are not saved.
- Each CLI gets only its own API key.
- Codex runs under a permission profile that makes only the snapshot, the system folders its commands need and its own install folder readable, with no writes and no network. The install folder is never a shared one like `~/.local`, and never one that holds your home folder or Codex's home and its login, with every path compared after symlinks are resolved; when codex is installed where that can't be avoided, `lenses.sh` refuses to run it. Its hosted web search is turned off, because that runs on OpenAI's side, where the profile can't reach. The commands it runs get only basic variables such as `PATH` and `HOME`, never `CODEX_API_KEY`. Codex's own `--sandbox read-only` is not used: it lets commands read the whole disk, home directory included, and silently overrides the profile. Without an API key, Codex loads your global `AGENTS.md`.

## refute.sh

```
refute.sh <repo-dir> <claude|codex> <claims.md>...
```

The check in step 4 of the audit. Each claims file holds numbered `## Claim <n>` blocks, a location, a trigger and a consequence each, written by the audit session with no word of who found them or what severity they were given. Each file is one run, on the same snapshot and in the same sandbox as the lenses, with `refute.md` as the instructions: read `THREAT-MODEL.md` first, then try to prove each claim wrong, read only, no exploit. The reply is one verdict per claim, `REFUTED` with what stops it at file:line, `PARTLY`, or `STANDS` with the whole path traced, plus whether the threat model documents it, the severity under its rules, and the preconditions. Results go to `<repo>/audit/refute/<timestamp>/<provider>/<name>.md`, with a `.log` each and a `run.txt` in the same shape as the lens pass; a second run started in the same second gets `-2` on its timestamp, so two never share a folder. A run that fails, is refused or doesn't answer in that shape leaves only its `.log`, and an `ok` line names any claim that got no verdict, so a refusal or a skipped claim is never read as "refuted". The settings, keys and sandboxes are the ones above; `reviewers.sh` holds them for both scripts.

## CI

The workflow expects sentinel as a submodule at `.sentinel`, which `/snt:onboard` sets up. Copy `ci/fast.yml` into `.github/workflows/` or `.forgejo/workflows/`, and add the secret `ANTHROPIC_API_KEY`. GitHub keeps Actions secrets per repository, encrypted in its settings and never in git, so each repo needs its own; `/snt:onboard` asks you to set it in your own terminal, where `gh` prompts for the key so it never passes through Claude:

```sh
gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>
```

If the project needs system libraries to build, add them to the install step.

`fast.yml` runs on every pull request, every push to `main`, and once a week on `main`, Mondays at 06:17 UTC, so a new advisory against a dependency already in use shows up without waiting for a pull request. The `mechanical` job runs on all three, on GitHub and Forgejo, and runs check.sh with the gating tools, gitleaks, shellcheck and zizmor. It fetches the whole history so gitleaks can read it, and it never runs the fuzz targets, because CI does not set `SENTINEL_FUZZ_SECONDS`. The `security-review` job runs `ci/security-review.sh` alongside it, on GitHub pull requests from the repository itself only, because it posts its result as one pull request comment through the GitHub API, rewritten on each push, and a pull request from a fork gets no secrets, so it skips the job instead of failing it. A newer push to a pull request cancels the run of the older one. It does not wait for the mechanical job, so a failing gate, such as a new advisory against a dependency already in use, does not skip the review. It installs a pinned Claude Code (2.1.300) on Node 22, has Claude Opus 5.5 review the pull request's diff against `THREAT-MODEL.md` with read-only tools and none of the pull request's own `.claude` settings loaded, and writes the review in the finding format. The checkout keeps no GitHub token in `.git/config`, the reviewer is refused any read outside the checkout and inside `.git`, and output that contains the API key is deleted and fails the job instead of being posted. The job fails when the review did not run or its output holds neither findings nor a "No findings" marker, so a passing check means a review happened. Findings do not fail the job; they are posted for the author to read. The actions the workflow uses are pinned to commits, not tags. Pull requests opened by Dependabot skip the review, because GitHub gives them no Actions secrets; the mechanical job's dependency checks still run on them. On a runner without rustup, `install-tools.sh` downloads a pinned rustup-init version and refuses it unless its SHA-256 matches the one in the script. It pins cargo-audit, cargo-deny, semgrep, gitleaks, shellcheck and zizmor to versions in the script too, and checks the gitleaks and shellcheck downloads against their SHA-256 the same way.

On a public repo the comment, the job log and the job summary are public, and a review can describe a bug in code that is already released. Set the repository variable `SENTINEL_REVIEW_AGE_RECIPIENT` to your [age](https://github.com/FiloSottile/age) public key and the job installs age, encrypts the review to the `security-review` artifact (kept 14 days), and the comment, log and summary show only the count of findings by severity. The artifact is readable by anyone who can read the repo, but only your key opens it. Read it from the repo's checkout:

```sh
.sentinel/ci/read-review.sh <pull request number>
```

It finds the newest `fast.yml` run for the pull request's head commit, downloads the artifact to a temporary folder, and prints it with control characters removed after decrypting it with `~/.config/sentinel/age.key`, or the identity in `SENTINEL_AGE_IDENTITY` or its second argument. Without the variable the whole review is posted, as before.

A pull request runs its own copy of `fast.yml` and of the kit's scripts, so whoever opens it controls what its review job does. The review helps trusted authors catch mistakes; it is not a gate against them. Limit who can open pull requests to collaborators (`gh api -X PATCH repos/<owner>/<repo> -f pull_request_creation_policy=collaborators_only`); `/snt:onboard` checks this, along with the rulesets that make the two checks required, secret scanning and Dependabot, and gives you the command for each one that is missing. `read-review.sh` reads only a review from a run of the repo's own `fast.yml` on one of its own branches, never one from a fork, which never gets the API key and so can only hold a forged review.

The action pins in `ci/fast.yml`, the tool versions and hashes in `ci/install-tools.sh` and the Claude Code version are bumped here by hand. Dependabot bumps the copy of `fast.yml` in your repo, and check.sh then reports the difference between the copy and the kit's, which is the sign the kit's pins are behind.

The diff is untrusted input, and text in it can try to steer the review. The prompt tells Claude to treat it as data, which narrows that but cannot rule it out, so the review is for trusted pull requests; require approval for workflows from outside contributors. `SENTINEL_REVIEW_MODEL` and `SENTINEL_REVIEW_EFFORT` override the model and effort.

The full audit has no workflow. It needs a Claude Code session for the Claude Security scan, and its findings must stay off public CI, so it runs only on your machine through `/snt:audit`. What CI can check is that it happened and what it covered: the release gate in [The stamp](#the-stamp).

On Forgejo, the `ubuntu-latest` label must be mapped to an image on the runner.

## What stays manual

- Checking every `[VERIFY]` mark `/snt:onboard` leaves in `THREAT-MODEL.md`, and keeping the threat model current.
- Checking the Claude Security report against `THREAT-MODEL.md`. Claude Security builds its own threat model and does not read yours, so check that every trust boundary yours names was looked at, and rerun the scan with `--scope` on any it missed.
- Deciding what to do with the findings. `/snt:audit` only finds and records.
- Committing. Neither skill commits anything, `SENTINEL.md` included: the audit writes it and you commit it.
- Running the settings commands `/snt:onboard` gives you, and adding the release gate to a repo onboarded before the kit had one.
