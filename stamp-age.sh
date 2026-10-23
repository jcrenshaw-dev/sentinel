#!/usr/bin/env bash
# Say how far a repo has moved since the audit its SENTINEL.md records.
#
# Usage: stamp-age.sh [repo-dir=.]
#
# Finds the commit on SENTINEL.md's "Commit audited:" line, trying each hex
# string on it until one names a commit in the repo. Prints that commit and
# how many commits HEAD is ahead of it, then the files changed since, in the
# working tree as it is now, untracked files included, counted by folder and
# then listed. SENTINEL.md itself is left out. git quotes any file name with
# control characters in it.
#
# Exits 0 when no file but SENTINEL.md changed after the commit it names,
# 1 when other files did, and 2 when there is no SENTINEL.md or its line
# names no commit in the repo. As a step in a release workflow, 1 and 2 both
# stop the release: one the last audit did not cover, or one with no audit
# record at all.
set -euo pipefail

repo=$(realpath "${1:-.}")
stamp="$repo/SENTINEL.md"
[[ -f $stamp ]] || { echo "SENTINEL.md is missing"; exit 2; }

line=$(grep -m 1 '^Commit audited:' "$stamp" || true)
commit=""
for tok in $(grep -oE '\b[0-9a-f]{7,40}\b' <<< "$line" || true); do
    if git -C "$repo" rev-parse -q --verify "$tok^{commit}" >/dev/null; then
        commit=$(git -C "$repo" rev-parse --short "$tok^{commit}")
        break
    fi
done
if [[ -z $commit ]]; then
    echo "SENTINEL.md names no commit in this repo on its \"Commit audited:\" line"
    exit 2
fi

# The commit that adds SENTINEL.md always comes after the one it names, so
# the audit is current when nothing else changed since. The diff is against
# the working tree, not HEAD, so uncommitted and untracked files count too:
# the audit never saw them either.
ahead=$(git -C "$repo" rev-list --count "$commit..HEAD")
files=$({
    git -C "$repo" diff --name-only "$commit" -- . ':(exclude)SENTINEL.md'
    git -C "$repo" ls-files --others --exclude-standard -- . ':(exclude)SENTINEL.md'
} | sort -u)
count=$(grep -c . <<< "$files" || true)
if [[ $count -eq 0 ]]; then
    echo "SENTINEL.md describes $commit, and no file but SENTINEL.md has changed since"
    exit 0
fi
echo "SENTINEL.md describes $commit; HEAD is $ahead commit$([[ $ahead -eq 1 ]] || echo s) ahead, with $count file$([[ $count -eq 1 ]] || echo s) changed"
echo
echo "Changed files by folder:"
sed -E 's#/[^/]+$##; t; s#.*#.#' <<< "$files" | sort | uniq -c | sort -rn
echo
echo "Changed files:"
sed 's/^/  /' <<< "$files"
exit 1
