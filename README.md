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

1. **Mechanical checks.** `.sentinel/mechanical/check.sh .`, with its output saved to `audit/check.txt`.
2. **Claude Security scan.** `/claude-security`, a release, branch or quick scan, picked when the step starts. Its report is copied to `audit/claude-security.md`. Its suggest-patches job is never run.
3. **Findings log.** One row per step in `audit/findings-log.md`.

Everything the audit writes goes under `audit/`, apart from Claude Security's own `CLAUDE-SECURITY-<timestamp>/` folder. `/snt:onboard` puts both in `.gitignore`, because they hold unfixed vulnerability findings.

## What is in it

| Path | What it is |
|------|------------|
| `.claude-plugin/`, `skills/` | The `snt` plugin: the `onboard` and `audit` skills, and the marketplace entry that installs them. |
| `threat-model.template.md` | The template for a project's `THREAT-MODEL.md`. The pull request review reads it first, and `/snt:onboard` copies its key points into the security-guidance rules. |
| `finding-format.md` | The format the pull request review writes its findings in. |
| `skills/<name>/steps.md` | The steps of `/snt:audit` and `/snt:onboard`. The plugin's skills are short stubs that read these from the project's `.sentinel`, so the steps always match the pinned kit. |
| `mechanical/check.sh` | Runs cargo audit, cargo deny, clippy, semgrep and the rest, depending on what the repo contains. |
| `mechanical/install.sh` | Installs those tools on Arch Linux. |
| `mechanical/deny.toml` | cargo-deny baseline. A repo's own `deny.toml` takes precedence. |
| `mechanical/semgrep.yml` | The semgrep rulesets check.sh runs, and the rules it skips. |
| `ci/fast.yml` | The pull request workflow for GitHub Actions and Forgejo Actions. |
| `ci/install-tools.sh` | Installs the mechanical tools on a Debian or Ubuntu CI runner. |
| `ci/security-review.sh`, `ci/security-review.md` | The pull request review `fast.yml` runs, and its prompt. |
| `ci/read-review.sh` | Decrypts a pull request's private review on your machine. |
| `findings-log.md` | The template for a project's `audit/findings-log.md`. |

## Requirements

- `bash`, `git`, `python3`.
- Claude Code, with the `claude-security` and `security-guidance` plugins from `claude-plugins-official`.
- The mechanical tools: `mechanical/install.sh` on Arch, `ci/install-tools.sh` on CI runners.

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
| `cargo +nightly miri test --workspace --lib --bins` (unit tests only: Miri cannot run tests that start processes) | the repo's own Rust code has an `unsafe` block, fn, impl, trait or extern, and nightly has Miri installed (CI runners skip it) | report |
| `npm audit` | `package.json` and `package-lock.json` exist | report |
| `pip-audit -r requirements.txt` and `pip-audit .`, one run for each that applies | `requirements.txt`, and `pyproject.toml` with a `[project]` table | report |
| `bandit -r .` | `pyproject.toml` or `requirements.txt` exists | report |

semgrep runs with `--metrics=off`. `semgrep.yml` also lists rules to skip: the three p/rust rules that flag reading the program's arguments or its own path (`args`, `args-os`, `current-exe`), which fire on every command-line tool.

## CI

The workflow expects sentinel as a submodule at `.sentinel`, which `/snt:onboard` sets up. Copy `ci/fast.yml` into `.github/workflows/` or `.forgejo/workflows/`, and add the secret `ANTHROPIC_API_KEY`. GitHub keeps Actions secrets per repository, encrypted in its settings and never in git, so each repo needs its own; `/snt:onboard` asks you to set it in your own terminal, where `gh` prompts for the key so it never passes through Claude:

```sh
gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>
```

If the project needs system libraries to build, add them to the install step.

`fast.yml` runs on every pull request. The `mechanical` job runs check.sh with the gating tools on GitHub and Forgejo. The `security-review` job then runs `ci/security-review.sh`, on GitHub only, because it posts its result as a pull request comment through the GitHub API. It installs a pinned Claude Code (2.1.300) on Node 22, has Claude Opus 5.5 review the pull request's diff against `THREAT-MODEL.md` with read-only tools and none of the pull request's own `.claude` settings loaded, and writes the review in the finding format. The checkout keeps no GitHub token in `.git/config`, the reviewer is refused any read outside the checkout and inside `.git`, and output that contains the API key is deleted and fails the job instead of being posted. The job fails when the review did not run or its output holds neither findings nor a "No findings" marker, so a passing check means a review happened. Findings do not fail the job; they are posted for the author to read. The actions the workflow uses are pinned to commits, not tags. Pull requests opened by Dependabot skip the review, because GitHub gives them no Actions secrets; the mechanical job's dependency checks still run on them. On a runner without rustup, `install-tools.sh` downloads a pinned rustup-init version and refuses it unless its SHA-256 matches the one in the script.

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
