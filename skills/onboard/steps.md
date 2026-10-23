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

## Finish

List every file created or changed, and anything marked `[VERIFY]` that the user still needs to check.
