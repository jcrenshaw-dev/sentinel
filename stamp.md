# The stamp

`/snt:audit` writes everything below the line to the repo root as `SENTINEL.md` at the end of step 5, and the user commits it. It describes the last audit only, so an existing file is overwritten. Fill every `<...>` from this audit's results; the last section stays word for word, apart from its one marked line. Counts only: never a finding's title, location or any text a secret could be read from. This file in sentinel stays a template.

---

# Security audit record

This repository is audited with [sentinel](https://github.com/jcrenshaw-dev/sentinel), a kit of static checks and model reviews the maintainer runs before a release. The audit finds and records. It fixes nothing, and the maintainer decides what to do with each finding. This file is written by the audit and committed by the maintainer, and it describes the last audit only.

Audited: <date>
Commit audited: `<short hash>`
sentinel commit: `<short hash>`
Threat model: `THREAT-MODEL.md` describes `<short hash>`, <current at the audit | <N> commits behind it at the audit, with <N> production files changed since; the audit ran with that gap recorded>

## What ran

- **Mechanical checks** (`check.sh`): gates <cargo deny, cargo clippy and semgrep, each PASS or FAIL, or "none ran: no Cargo.toml" and the gates that did>. Reports: <each report that ran, with one phrase on what it found or "nothing">. Fuzzing: <<N> targets for <N> seconds each, <N> crashes | not run>.
- **Claude Security**: <release scan of the whole repository at medium | branch scan of `<branch>` against `<base>` at high | quick scan of the whole repository at low>. <N> findings: <N> critical, <N> high, <N> medium, <N> low. Coverage: <every production file was covered | <N> production files were not covered and a scoped scan covered them | <N> production files were not covered and were not scanned>.
- **Lenses**: <eight review prompts, one concern each, run on <Claude (`<model>`) | Codex (`<model>`) | Claude (`<model>`) and Codex (`<model>`)> | skipped>. <<provider>: <N> of 8 runs made a report<, <lens> <BLOCKED | UNPARSEABLE | FAILED>>, for each provider>.
- **Check of the lens findings**: each finding went to reviewers as a neutral claim, with no word of which model or lens found it or what severity it was given, and the reviewers tried to prove it wrong. <N> stood, <N> stood in part, <N> were refuted, <N> were set aside as already covered by Claude Security or `THREAT-MODEL.md`.
- **Coverage**: <every production file was read by at least one reviewer | <N> production files were read by no reviewer; this audit is not complete until they are>.

## Open findings

Counts from the maintainer's register. The details of an open finding are not published until it is fixed.

| Severity | Open | Accepted |
|----------|------|----------|
| critical | <N> | <N> |
| high | <N> | <N> |
| medium | <N> | <N> |
| low | <N> | <N> |

An accepted finding is one the maintainer has decided not to fix, with the reason recorded in the register. Those accepted because the behavior is by design are documented in `THREAT-MODEL.md`.

## What this record does not say

- The audit's tools build the code, run its fuzz targets and its unit tests under Miri, and read the rest. Nobody attacked the running program, wrote an exploit or demonstrated a finding. A finding is a path traced through the code, with a trigger and a consequence named.
- The reviewers are language models running fixed prompts. They miss things. A step that found nothing is not proof there is nothing to find.
- <The findings from the Claude lenses and from Claude Security were checked by Claude, the same model family that found them. | Every finding was checked by a different model family than the one that found it.>
- This record covers the commit named above and nothing after it. `.sentinel/stamp-age.sh .` lists the files changed since, and a release gate built on it stops a release the audit did not cover.
