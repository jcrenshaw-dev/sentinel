# sentinel walkthrough

How a project goes from nothing to audited. There are three parts: set up the machine once, onboard each project once, and audit when it matters.

## 1. Set up the machine (once)

**Tools.** Run the installer from your sentinel checkout, or from any onboarded project's `.sentinel/`. It uses sudo for pacman and installs the cargo tools, Miri and the pipx tools for your user:

```sh
<your sentinel checkout>/mechanical/install.sh
```

Run it again whenever you want newer versions of the tools.

**Plugins.** sentinel uses two plugins besides its own:

```sh
claude plugin marketplace add jcrenshaw-dev/sentinel
claude plugin install snt@sentinel

claude plugin install claude-security@claude-plugins-official
claude plugin install security-guidance@claude-plugins-official
```

**Keys.** The audit runs on your claude.ai login, so it needs no key on your machine. Keep the Anthropic API key in your password manager. Its only job is the GitHub secret for the pull request review (onboarding step 6). It must be scoped to a workspace: an unscoped key fails with a 400 asking for an `anthropic-workspace-id` header. Never export `ANTHROPIC_API_KEY` in your shell: every interactive Claude Code session would see it next to your claude.ai login.

**CLIs.** `claude` on PATH. For a lens pass on Codex, `codex` on PATH too, with `OPENAI_API_KEY` set or a Codex login.

## 2. Onboard a project (once per repo)

Open Claude Code in the repo and run:

```
/snt:onboard
```

It stops after each step for you to look. If a step is already done, it says so and moves on.

| Step | What it does | What you check |
|------|--------------|----------------|
| 1. Add the kit | `git submodule add https://github.com/jcrenshaw-dev/sentinel .sentinel`, and `audit/` plus `CLAUDE-SECURITY-*/` into `.gitignore` | Both ignore lines are there. Those two folders hold unfixed findings. |
| 2. THREAT-MODEL.md | Written from the code: what the tool reads, writes, executes, must never touch, and where untrusted data enters. Unsure claims are marked `[VERIFY]`. | Every `[VERIFY]` mark. The pull request review treats this file as the definition of what matters, step 3 is built from it, and you check each audit's Claude Security report against it. |
| 3. Security-guidance rules | `.claude/claude-security-guidance.md`: a short threat model plus a codebase-specific checklist, which the security-guidance plugin adds to its reviews | It stays well under 8 KB and holds no secrets. |
| 4. Fuzz targets (Rust) | cargo-fuzz targets for every function that parses outside input (JSONL, config, CLI, MCP payloads), in the crate that owns it, each one built | They all compile and the main build still works. It also reports whether the code has `unsafe`; check.sh runs Miri on its own when it does. |
| 5. deny.toml (Rust) | The baseline copied to the repo root, its license list fitted to the real dependencies, then `cargo deny check` | Read the output. Nothing gets fixed yet. |
| 6. Fast CI workflow | `.github/workflows/fast.yml` (or `.forgejo/workflows/`), and the repo's `ANTHROPIC_API_KEY` Actions secret, which you set in your own terminal with `gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>` when it asks. On a public repo, also the `SENTINEL_REVIEW_AGE_RECIPIENT` variable holding your age public key, so reviews are encrypted instead of posted | `gh secret list -R <owner>/<repo>` shows the secret and `gh variable list -R <owner>/<repo>` the variable. The key lives encrypted in GitHub's settings, never in git. |
| 7. SECURITY.md | How to report, what runs on every pull request and every push to `main`, what the full audit runs, and a link to sentinel | It asks you for the reporting contact. It never makes one up. |

At the end it lists every file it created or changed. It does not commit; review the list and commit it yourself.

Onboarding never runs the audit.

## 3. Audit (when it matters)

Open Claude Code in the repo and run:

```
/snt:audit
```

It stops after each step.

| Step | What it does | What you look at |
|------|--------------|------------------|
| 1. Mechanical checks | `check.sh`: cargo audit, cargo deny, clippy and semgrep as gates; geiger, vet, fuzz build, a run of each fuzz target (60 seconds each, or `SENTINEL_FUZZ_SECONDS`), Miri, gitleaks over the whole git history, shellcheck, zizmor, npm audit, pip-audit and bandit as reports. Its output is saved to `audit/check.txt`. | Failures by tool, and the path of any fuzz artifact. Nothing gets fixed in this session. |
| 2. Claude Security scan | `/claude-security`, a release, branch or quick scan, picked when the step starts; its report is copied to `audit/claude-security.md` | The findings by severity, any ALERT line about production files the scan did not cover, and, after a release scan, whether it looked at every trust boundary `THREAT-MODEL.md` names. Rerun it with `--scope` on any it missed. |
| 3. Lens pass | Asks Claude, Codex, both or skip, with the cost, then runs `.sentinel/lenses.sh` | Your choice. Nothing runs until you make it. |
| 4. Check | Read-only subagents trace each lens finding that is new, and write the confirmed ones to `audit/lenses.md` | The confirmed findings by severity, and the list of what was set aside and why. |
| 5. Findings log | One row per step in `audit/findings-log.md`: the tools that failed, and the findings by severity for Claude Security and the lenses | The notes column is yours to fill in. |

Where everything lands:

| Path | What it holds |
|------|---------------|
| `audit/check.txt` | The mechanical checks' output |
| `audit/claude-security.md` | The Claude Security report |
| `audit/claude-security-skipped.md` | The scoped scan of files the main scan did not cover, if it ran |
| `CLAUDE-SECURITY-<timestamp>/` | Claude Security's own run folder |
| `audit/lenses/<timestamp>/` | Each lens's raw output and log, per provider |
| `audit/lenses.md` | The checked lens findings |
| `audit/findings-log.md` | The running log for this repo |

`audit/` and `CLAUDE-SECURITY-*/` stay out of git. The audit fixes nothing, writes no tests and commits nothing. What you do with the findings is up to you.

On a public repo, keep findings to yourself until they're fixed: no issue, no commit message and no post that describes an open one.

## 4. Keeping it running

| When | What to do |
|------|------------|
| Every pull request, and every push to `main` | `fast.yml` runs by itself: the mechanical checks, and on a pull request Claude Opus 5.5 reviewing the diff alongside them and posting the result as a comment. On a public repo with the age variable set, the comment holds only the count of findings; read the review with `.sentinel/ci/read-review.sh <pull request number>`. The check fails if the review didn't actually run. The review runs only on pull requests; a push straight to `main` gets the mechanical checks alone. |
| Before a release | `/snt:audit`, then decide what to do with what it finds. |
| When the tool gains a new input, output, command or hook | Update `THREAT-MODEL.md` and `.claude/claude-security-guidance.md` first, then audit. The pull request review and your check of the Claude Security report both work from the threat model. |
| When sentinel changes | Move the project's pin and commit it: `git submodule update --remote .sentinel` |
| When the snt plugin changes | `claude plugin marketplace update sentinel && claude plugin update snt@sentinel`, then restart Claude Code |
| Now and then | Rerun `mechanical/install.sh` to update the tools. |

There is no scheduled audit in CI. The full audit runs only on your machine, with `/snt:audit`.
