# Onboard this repo to sentinel

This repository is being onboarded to the sentinel security-audit kit (https://github.com/jcrenshaw-dev/sentinel). Work through the steps below in order. After each step, stop, show the user the result, and wait for them to say continue. If a step is already done (the file exists and is filled in), say so and move on to the next one.

Do not run the audit in this session. Do not commit anything; list every file you created or changed at the end so the user can review and commit.

## 1. Add the kit

- Add sentinel as a git submodule at `.sentinel`:
  `git submodule add https://github.com/jcrenshaw-dev/sentinel .sentinel`
- Add `audit/` and `CLAUDE-SECURITY-*/` to `.gitignore`. They hold unfixed vulnerability findings and must never be committed.
- Read `.sentinel/README.md`.

## 2. Write THREAT-MODEL.md

Write `THREAT-MODEL.md` at the repo root from `.sentinel/threat-model.template.md`. Fill it from the actual code, not from assumptions: trace what this tool reads, writes, executes, and where untrusted data enters. Transcripts from `~/.claude/projects` are untrusted because they contain tool output and web content. Mark every claim you are unsure of with `[VERIFY]`.

## 3. Write the security-guidance rules

Copy THREAT-MODEL.md's key points into `.claude/claude-security-guidance.md`, the file the security-guidance plugin reads. That plugin appends the file to every security review prompt as additive project rules, so:

- Write plain markdown: a short plain-language threat model, then a review checklist of rules specific to this codebase (what it must never touch, where untrusted data enters, which calls need which guard). Leave out generic advice the model already knows.
- Keep it well under 8 KB. The plugin's budget is 8 KB for this file and the user's own `~/.claude/claude-security-guidance.md` together, and it truncates past that.
- No secrets: the contents are sent with every review.

## 4. Fuzz targets and unsafe code (Rust only)

Skip this step if the repo has no `Cargo.toml`.

- Add cargo-fuzz targets for every function that parses external input: JSONL, config, CLI arguments, MCP payloads. Put each `fuzz/` directory in the crate that owns the function: the repo root for a single package, the member crate's directory in a workspace (a virtual workspace root cannot hold one).
- Each target must compile: run `cargo +nightly fuzz build` in each crate that has a `fuzz/` directory, and show the result. Check that the main workspace still builds afterwards.
- Report whether the repo's own code has any `unsafe`. You do not need to add anything for it: check.sh runs Miri on the unit tests (`cargo +nightly miri nextest run --workspace --lib --bins`) by itself when the repo has unsafe code.

## 5. deny.toml (Rust only)

Skip this step if the repo has no `Cargo.toml`.

Copy `.sentinel/mechanical/deny.toml` to the repo root and adjust the license allow-list to what this repo actually depends on (`cargo deny list` shows the licenses in use). Then run `cargo deny check` and show the output. Do not fix anything yet.

## 6. Fast CI workflow

Copy `.sentinel/ci/fast.yml` into `.github/workflows/fast.yml`, or into `.forgejo/workflows/fast.yml` if the repo lives on a Forgejo instance (check `git remote -v`). The file works on both.

The workflow's security-review job runs on GitHub only and needs the repo's `ANTHROPIC_API_KEY` Actions secret. If the repo has a GitHub remote, check with `gh secret list -R <owner>/<repo>`. If the secret is missing, tell the user to set it in their own terminal, where `gh` prompts for the key so it never passes through the conversation:

```
gh secret set ANTHROPIC_API_KEY -R <owner>/<repo>
```

Never ask for the key in the conversation and never print it. When they say it is done, check again with `gh secret list`.

If the repo is public (`gh repo view <owner>/<repo> --json visibility -q .visibility`), the review must not be posted in full, because a finding about code that is already released would be public before it is fixed. Check for the repository variable with `gh variable list -R <owner>/<repo>`. If `SENTINEL_REVIEW_AGE_RECIPIENT` is missing, tell the user to make an age key in their own terminal if they have none yet; one key serves every repo:

```
mkdir -p -m 700 ~/.config/sentinel && age-keygen -o ~/.config/sentinel/age.key
```

`age-keygen` prints the public key, which starts with `age1` and is not secret. Then they set the variable:

```
gh variable set SENTINEL_REVIEW_AGE_RECIPIENT -R <owner>/<repo> --body <age1... public key>
```

With it set, the review is encrypted and the comment shows only the count of findings; `.sentinel/ci/read-review.sh <pull request number>` decrypts it.

## 7. SECURITY.md

Add a `SECURITY.md` with:

- How to report a vulnerability. Ask the user for the contact or channel; never make one up.
- That the repository is audited with sentinel, with a link to https://github.com/jcrenshaw-dev/sentinel, and that the record of the last audit is `SENTINEL.md` at the repo root once an audit has run: what ran, how it went, and the open findings as counts. Say that the audit only finds and records: it fixes nothing and writes no tests.
- What runs on every pull request and every push to main, in a sentence or two: the workflow from step 6 and whether it fails the pull request. For the full list of checks, point at the kit's README in the `.sentinel` submodule, which is pinned to the version this repo runs, instead of restating it, so the file does not go stale when the kit changes.

## 8. Repository settings and the release gate (GitHub only)

Skip this step if the repo has no GitHub remote. Everything here is a setting the pull request review's safety depends on, or a check that runs when no one has opened a pull request. Check each one with `gh`, show what is set, and for each one that is missing give the user the command to run in their own terminal, in one message at the end of the step. Never run these commands yourself: they change the repository for everyone who uses it, and the user has to say yes to each.

- **Who can open pull requests.** A pull request runs its own copy of `fast.yml`, so whoever opens one controls what its review job does. Check `gh api repos/<owner>/<repo> --jq .pull_request_creation_policy`. If it is not `collaborators_only`:
  `gh api -X PATCH repos/<owner>/<repo> -f pull_request_creation_policy=collaborators_only`
  Say what it means: people outside the repo's collaborators cannot open pull requests at all.
- **Rulesets.** List them with `gh api repos/<owner>/<repo>/rulesets --jq '.[] | "\(.id) \(.target) \(.name) \(.enforcement)"'` and read each with `gh api repos/<owner>/<repo>/rulesets/<id>`. The branch ruleset on the default branch has to block deletion and force pushes, require a pull request, and require the `mechanical` and `security-review` checks; the tag ruleset has to block deleting, moving or force-pushing any tag, so a published release can't be swapped. For whichever is missing:
  `gh api -X POST repos/<owner>/<repo>/rulesets --input .sentinel/ci/ruleset-main.json`
  `gh api -X POST repos/<owner>/<repo>/rulesets --input .sentinel/ci/ruleset-tags.json`
  Say what the branch ruleset means: with no bypass actors, the owner also goes through a pull request with both checks green, and the review job has to finish, so an API outage holds a merge until the job is rerun. If the user wants to merge past a red check now and then, they add a bypass for the admin role in the ruleset's settings, and the record then means less. If the repo requires signed commits already, keep that rule when editing. A ruleset that exists but misses a check is edited by the user in the repo's settings; show which rule is missing.
- **Secret scanning and push protection.** Check `gh api repos/<owner>/<repo> --jq '.security_and_analysis | "secret scanning \(.secret_scanning.status), push protection \(.secret_scanning_push_protection.status)"'`. If either is not `enabled`:
  `gh api -X PATCH repos/<owner>/<repo> --input - <<< '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'`
- **Dependabot.** Alerts: `gh api repos/<owner>/<repo>/vulnerability-alerts` prints nothing when they are on and `404` when they are off; security updates: `gh api repos/<owner>/<repo>/automated-security-fixes --jq .enabled`. For whichever is off:
  `gh api -X PUT repos/<owner>/<repo>/vulnerability-alerts`
  `gh api -X PUT repos/<owner>/<repo>/automated-security-fixes`
  Version updates: if `.github/dependabot.yml` is missing, copy `.sentinel/ci/dependabot.yml` there and keep only the ecosystems the repo has: `github-actions` and `gitsubmodule` always, `cargo` with a `Cargo.toml`, `npm` with a `package.json`, `pip` with a `requirements.txt` or `pyproject.toml`. Say that the `gitsubmodule` entry opens a pull request whenever sentinel moves, which runs the new kit's checks before the pin changes.
- **The release gate.** If a workflow runs on `push: tags` or `release:`, show the user the `audited` job from the kit's README (section "The stamp") and where it would go in that workflow, and add it when they say so, with `needs: audited` on the jobs that build or publish. It runs `.sentinel/stamp-age.sh .`, which fails when any file changed since the commit `SENTINEL.md` names, or when there is no `SENTINEL.md` yet. Say that the first release after onboarding needs an audit first, since the stamp does not exist until `/snt:audit` has run. If there is no release workflow, say so and move on.

## Finish

List every file created or changed, anything marked `[VERIFY]` that the user still needs to check, and the settings from step 8 the user has not set yet.
