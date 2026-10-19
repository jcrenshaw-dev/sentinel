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

- `/snt:onboard` sets the repo up, once. It adds the kit as a git submodule at `.sentinel`, writes `THREAT-MODEL.md` from the code, the security-guidance rules, fuzz targets and `deny.toml` for Rust, the fast CI workflow and `SECURITY.md`. It stops after each step for you to look, and it does not run the audit.
- `/snt:audit` runs the audit below, stopping after each step. It finds and records; it does not fix, write tests or commit anything.

Each project runs the sentinel version its `.sentinel` submodule is pinned to. Updating a step or a script happens once here, and a project picks it up by moving its pin.

## The audit

What `/snt:audit` runs, in order:

1. **Mechanical checks.** `.sentinel/mechanical/check.sh .`, with each fuzz target run for 60 seconds and the output saved to `audit/check.txt`.
2. **Claude Security scan.** `/claude-security`, a release, branch or quick scan, picked when the step starts. Its report is copied to `audit/claude-security.md`. After a whole-repository scan, any production file the scan did not cover is flagged with an ALERT, and a scoped scan of those files is offered. Its suggest-patches job is never run.
3. **Lens pass.** Eight review prompts, one concern each, run once each on Claude, on Codex, on both, or skipped. You choose each time, and the question states the cost. `.sentinel/lenses.sh` runs them.
4. **Check.** Read-only subagents trace every lens finding the Claude Security report and `THREAT-MODEL.md` don't already cover, and only the confirmed ones reach `audit/lenses.md`.
5. **Findings log.** One row per step in `audit/findings-log.md`.

Everything the audit writes goes under `audit/`, apart from Claude Security's own `CLAUDE-SECURITY-<timestamp>/` folder. `/snt:onboard` puts both in `.gitignore`, because they hold unfixed vulnerability findings.

## What is in it

| Path | What it is |
|------|------------|
| `.claude-plugin/`, `skills/` | The `snt` plugin: the `onboard` and `audit` skills, and the marketplace entry that installs them. |
| `threat-model.template.md` | The template for a project's `THREAT-MODEL.md`. The pull request review reads it first, and `/snt:onboard` copies its key points into the security-guidance rules. |
| `lenses/*.md` | Eight review prompts, one concern each: data exposure, path handling, untrusted input, permissions, resource limits, hook execution, supply chain, crypto and state. |
| `lenses.sh` | Runs every lens once through `claude -p`, `codex exec` or both. |
| `finding-format.md` | The format the pull request review and the lenses write their findings in. |
| `skills/<name>/steps.md` | The steps of `/snt:audit` and `/snt:onboard`. The plugin's skills are short stubs that read these from the project's `.sentinel`, so the steps always match the pinned kit. |
| `mechanical/check.sh` | Runs cargo audit, cargo deny, clippy, semgrep and the rest, depending on what the repo contains. |
| `mechanical/install.sh` | Installs those tools on Arch Linux. |
| `mechanical/deny.toml` | cargo-deny baseline. A repo's own `deny.toml` takes precedence. |
| `mechanical/semgrep.yml` | The semgrep rulesets check.sh runs, and the rules it skips. |
| `ci/fast.yml` | The pull request and push-to-main workflow for GitHub Actions and Forgejo Actions. |
| `ci/install-tools.sh` | Installs the mechanical tools on a Debian or Ubuntu CI runner. |
| `ci/security-review.sh`, `ci/security-review.md` | The pull request review `fast.yml` runs, and its prompt. |
| `ci/read-review.sh` | Decrypts a pull request's private review on your machine. |
| `findings-log.md` | The template for a project's `audit/findings-log.md`. |

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
| `semgrep scan --error` with the rulesets in `semgrep.yml` | always | gate |
| `cargo geiger`, once per workspace member | `Cargo.toml` exists | report |
| `cargo vet --locked` | `supply-chain/` exists | report |
| `cargo +nightly fuzz build` | a `fuzz/` directory at the root or in any workspace member | report |
| `cargo +nightly fuzz run` on each target `cargo fuzz list` names, for `SENTINEL_FUZZ_SECONDS` seconds each. It shows only the lines that say what happened and the path of each new artifact, never the crashing input. | a `fuzz/` directory, and `SENTINEL_FUZZ_SECONDS` set (`/snt:audit` sets it to 60 unless it is already set; CI does not set it) | report |
| `cargo +nightly miri test --workspace --lib --bins` (unit tests only: Miri cannot run tests that start processes) | the repo's own Rust code has an `unsafe` block, fn, impl, trait or extern, and nightly has Miri installed (CI runners skip it) | report |
| `gitleaks git --redact` over every commit on every ref. It shows only each finding's fingerprint (`commit:file:rule:line`), never the secret or the line it is on. | the repo is a git checkout | report |
| `npm audit` | `package.json` and `package-lock.json` exist | report |
| `pip-audit -r requirements.txt` and `pip-audit .`, one run for each that applies | `requirements.txt`, and `pyproject.toml` with a `[project]` table | report |
| `bandit -r .` | `pyproject.toml` or `requirements.txt` exists | report |

semgrep runs with `--metrics=off`. `semgrep.yml` also lists rules to skip: the three p/rust rules that flag reading the program's arguments or its own path (`args`, `args-os`, `current-exe`), which fire on every command-line tool.

## lenses.sh

```
lenses.sh <repo-dir> <claude|codex|both>
```

Each lens runs once on each provider you name. Claude runs three lenses at a time and Codex four, and with `both` Claude finishes before Codex starts. Results go to `<repo>/audit/lenses/<timestamp>/<provider>/<lens>.md`, each with a `.log`, plus `run.txt` recording the commit, models and settings. A run that fails leaves only its `.log`.

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

## CI

The workflow expects sentinel as a submodule at `.sentinel`, which `/snt:onboard` sets up. Copy `ci/fast.yml` into `.github/workflows/` or `.forgejo/workflows/`, and add the secret `ANTHROPIC_API_KEY`. GitHub keeps Actions secrets per repository, encrypted in its settings and never in git, so each repo needs its own; `/snt:onboard` asks you to set it in your own terminal, where `gh` prompts for the key so it never passes through Claude:

```sh
gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>
```

If the project needs system libraries to build, add them to the install step.

`fast.yml` runs on every pull request and every push to `main`. The `mechanical` job runs on both, on GitHub and Forgejo, and runs check.sh with the gating tools and gitleaks. It fetches the whole history so gitleaks can read it, and it never runs the fuzz targets, because CI does not set `SENTINEL_FUZZ_SECONDS`. The `security-review` job runs `ci/security-review.sh` alongside it, on GitHub pull requests only, because it posts its result as a pull request comment through the GitHub API. It does not wait for the mechanical job, so a failing gate, such as a new advisory against a dependency already in use, does not skip the review. It installs a pinned Claude Code (2.1.300) on Node 22, has Claude Opus 5.5 review the pull request's diff against `THREAT-MODEL.md` with read-only tools and none of the pull request's own `.claude` settings loaded, and writes the review in the finding format. The checkout keeps no GitHub token in `.git/config`, the reviewer is refused any read outside the checkout and inside `.git`, and output that contains the API key is deleted and fails the job instead of being posted. The job fails when the review did not run or its output holds neither findings nor a "No findings" marker, so a passing check means a review happened. Findings do not fail the job; they are posted for the author to read. The actions the workflow uses are pinned to commits, not tags. Pull requests opened by Dependabot skip the review, because GitHub gives them no Actions secrets; the mechanical job's dependency checks still run on them. On a runner without rustup, `install-tools.sh` downloads a pinned rustup-init version and refuses it unless its SHA-256 matches the one in the script. It pins cargo-audit, cargo-deny, semgrep and gitleaks to versions in the script too, and checks gitleaks's download against its SHA-256 the same way.

On a public repo the comment, the job log and the job summary are public, and a review can describe a bug in code that is already released. Set the repository variable `SENTINEL_REVIEW_AGE_RECIPIENT` to your [age](https://github.com/FiloSottile/age) public key and the job installs age, encrypts the review to the `security-review` artifact (kept 14 days), and the comment, log and summary show only the count of findings by severity. The artifact is readable by anyone who can read the repo, but only your key opens it. Read it from the repo's checkout:

```sh
.sentinel/ci/read-review.sh <pull request number>
```

It finds the newest `fast.yml` run for the pull request's head commit, downloads the artifact to a temporary folder, and prints it with control characters removed after decrypting it with `~/.config/sentinel/age.key`, or the identity in `SENTINEL_AGE_IDENTITY` or its second argument. Without the variable the whole review is posted, as before.

A pull request runs its own copy of `fast.yml` and of the kit's scripts, so whoever opens it controls what its review job does. The review helps trusted authors catch mistakes; it is not a gate against them. Limit who can open pull requests to collaborators (`gh api -X PATCH repos/<owner>/<repo> -f pull_request_creation_policy=collaborators_only`). `read-review.sh` reads only a review from a run of the repo's own `fast.yml` on one of its own branches, never one from a fork, which never gets the API key and so can only hold a forged review.

The diff is untrusted input, and text in it can try to steer the review. The prompt tells Claude to treat it as data, which narrows that but cannot rule it out, so the review is for trusted pull requests; require approval for workflows from outside contributors. `SENTINEL_REVIEW_MODEL` and `SENTINEL_REVIEW_EFFORT` override the model and effort.

The full audit has no workflow. It needs a Claude Code session for the Claude Security scan, and its findings must stay off public CI, so it runs only on your machine through `/snt:audit`.

On Forgejo, the `ubuntu-latest` label must be mapped to an image on the runner.

## What stays manual

- Checking every `[VERIFY]` mark `/snt:onboard` leaves in `THREAT-MODEL.md`, and keeping the threat model current.
- Checking the Claude Security report against `THREAT-MODEL.md`. Claude Security builds its own threat model and does not read yours, so check that every trust boundary yours names was looked at, and rerun the scan with `--scope` on any it missed.
- Deciding what to do with the findings. `/snt:audit` only finds and records.
- Committing. Neither skill commits anything.
