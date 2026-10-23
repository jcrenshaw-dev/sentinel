#!/usr/bin/env bash
# Say how far a repo's THREAT-MODEL.md is behind its HEAD.
#
# Usage: threat-model-age.sh [repo-dir=.]
#
# Finds the commit on THREAT-MODEL.md's "Version or commit this describes:"
# line, trying each hex string on it until one names a commit in the repo.
# Prints that commit and how many commits HEAD is ahead of it, then the files
# changed since, in the working tree as it is now, untracked files included,
# counted by folder and then listed. THREAT-MODEL.md itself is left out. git
# quotes any file name with control characters in it.
#
# Exits 0 when no file but THREAT-MODEL.md changed after the commit it names,
# 1 when other files did, and 2 when there is no THREAT-MODEL.md or its line
# names no commit in the repo.
set -euo pipefail

repo=$(realpath "${1:-.}")
tm="$repo/THREAT-MODEL.md"
[[ -f $tm ]] || { echo "THREAT-MODEL.md is missing"; exit 2; }

line=$(grep -m 1 '^Version or commit this describes:' "$tm" || true)
commit=""
for tok in $(grep -oE '\b[0-9a-f]{7,40}\b' <<< "$line" || true); do
    if git -C "$repo" rev-parse -q --verify "$tok^{commit}" >/dev/null; then
        commit=$(git -C "$repo" rev-parse --short "$tok^{commit}")
        break
    fi
done
if [[ -z $commit ]]; then
    echo "THREAT-MODEL.md names no commit in this repo on its \"Version or commit this describes:\" line"
    exit 2
fi

# The commit that updates THREAT-MODEL.md always comes after the one it
# names, so a model is current when nothing else changed since. The diff is
# against the working tree, not HEAD, because the audit reads the working
# tree: uncommitted and untracked files count too.
ahead=$(git -C "$repo" rev-list --count "$commit..HEAD")
files=$({
    git -C "$repo" diff --name-only "$commit" -- . ':(exclude)THREAT-MODEL.md'
    git -C "$repo" ls-files --others --exclude-standard -- . ':(exclude)THREAT-MODEL.md'
} | sort -u)
count=$(grep -c . <<< "$files" || true)
if [[ $count -eq 0 ]]; then
    echo "THREAT-MODEL.md describes $commit, and no file but THREAT-MODEL.md has changed since"
    exit 0
fi
echo "THREAT-MODEL.md describes $commit; HEAD is $ahead commit$([[ $ahead -eq 1 ]] || echo s) ahead, with $count file$([[ $count -eq 1 ]] || echo s) changed"
echo
echo "Changed files by folder:"
sed -E 's#/[^/]+$##; t; s#.*#.#' <<< "$files" | sort | uniq -c | sort -rn
echo
echo "Changed files:"
sed 's/^/  /' <<< "$files"
exit 1
