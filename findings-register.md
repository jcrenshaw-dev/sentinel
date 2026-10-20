# Findings register

Every finding this project's audits have reported, one row each, under an ID that stays the same from one audit to the next. `/snt:audit` keeps the filled-in copy for each project at `audit/findings.md` in that project, which stays out of git with the rest of `audit/`. This file in sentinel stays an empty template.

- **ID** is `<repo>-NNN`, numbered in the order findings were first seen. An ID is never reused.
- **Found by** lists every step that has reported it: `claude-security`, or `lenses (<provider>/<lens>)`.
- **Severity** is the latest one: Claude Security's own, or the one step 4's check gave a lens finding.
- **Last seen** is the date of the last audit that reported it.
- **Status** is `open` until you change it. Only you set `fixed` (give the commit) or `accepted` (give the reason). The audit never does, because a finding one run didn't report may only have been missed.
- **Notes**: when an audit doesn't report an open finding, it adds `not reported <date>`, and `check whether fixed` when the code at its location changed since it was last seen. The rest is yours.

| ID | title | location | severity | found by | first seen | last seen | status | notes |
|----|-------|----------|----------|----------|------------|-----------|--------|-------|
|    |       |          |          |          |            |           |        |       |
