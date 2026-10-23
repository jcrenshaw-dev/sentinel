#!/usr/bin/env bash
# Try to prove claims about a repo wrong, on Claude or Codex.
#
# Usage: refute.sh <repo-dir> <claude|codex> <claims.md>...
#
# Each claims file holds numbered claims, "## Claim <n>" blocks with a
# location, a trigger and a consequence, and no word of who found them or
# what severity they were given. Each file is one run on a snapshot of the
# repo, in the sandbox lenses.sh uses, with refute.md as the instructions.
# Writes <repo-dir>/audit/refute/<timestamp>/<provider>/<name>.md, one
# verdict per claim, a <name>.log next to each, and run.txt. A run that
# fails, ends in a refusal or doesn't answer in the shape refute.md asks for
# leaves only its .log, so a refusal is never read as "refuted". The snapshot,
# the sandboxes and the reviewers are in reviewers.sh, shared with lenses.sh.
set -euo pipefail

[[ $# -ge 3 ]] || { echo "usage: refute.sh <repo-dir> <claude|codex> <claims.md>..." >&2; exit 2; }
repo=$(realpath "$1")
case $2 in
    claude | codex) providers=("$2") ;;
    *) echo "refute.sh: provider must be claude or codex" >&2; exit 2 ;;
esac
shift 2

# shellcheck source=reviewers.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/reviewers.sh"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"
[[ -f $repo/THREAT-MODEL.md ]] || die "$repo/THREAT-MODEL.md is missing; fill in threat-model.template.md first"
check_tools
guard_codex

# One run per claims file, named after the file. The claims are counted so
# the reply can be checked for one verdict each.
declare -A expected
names=() claim_files=()
for f; do
    [[ -f $f ]] || die "$f is not a file"
    name=$(basename "$f" .md)
    [[ -z ${expected[$name]:-} ]] || die "two claims files are named $name"
    n=$(grep -c '^## Claim [0-9]' "$f" || true)
    [[ $n -gt 0 ]] || die "$f has no '## Claim <n>' heading"
    expected[$name]=$n
    names+=("$name")
    claim_files+=("$(realpath "$f")")
done

ts=$(date -u +%Y%m%dT%H%M%SZ)
make_out "$repo/audit/refute/$ts"
make_snapshot
set_keys

{
    run_header "$ts"
    for i in "${!names[@]}"; do
        echo "claims: ${names[$i]}, ${expected[${names[$i]}]} from ${claim_files[$i]}"
    done
} > "$out/run.txt"
cat "$out/run.txt"
echo

# check_report <file> fails when the reply has no "## Claim <n>" block at
# all. It prints one line for each claim the reply skipped, gave no verdict
# or a verdict that isn't REFUTED, PARTLY or STANDS, and for each claim
# number that was never asked, by number only.
check_report() {
    local name
    name=$(basename "${1%.md.part}")
    awk -v expected="${expected[$name]}" '
        /^```/ { fence = !fence; next }
        fence { next }
        /^## Claim [0-9]+/ { n = $3; sub(/[^0-9].*/, "", n); seen[n] = 1; cur = n; found = 1; next }
        /^## / { cur = ""; next }
        cur != "" && match(tolower($0), /^[-*][[:space:]]*`?verdict`?[[:space:]]*:/) {
            v = toupper(substr($0, RLENGTH + 1)); sub(/^[^A-Z]+/, "", v); sub(/[^A-Z].*$/, "", v)
            if (v == "REFUTED" || v == "PARTLY" || v == "STANDS") verdict[cur] = v
            else print "claim " cur " has an unknown verdict"
        }
        END {
            for (i = 1; i <= expected; i++) {
                if (!(i in seen)) print "claim " i " is missing"
                else if (!(i in verdict)) print "claim " i " has no verdict"
            }
            for (n in seen) if (n + 0 < 1 || n + 0 > expected) print "claim " n " was not asked"
            exit !found
        }' "$1"
}

for i in "${!names[@]}"; do
    { cat "$sentinel/refute.md"; echo; cat "${claim_files[$i]}"; } > "$work/${names[$i]}.prompt.md"
done

failed=0 total=0
run_batch "${providers[0]}" "${names[@]}"

echo
echo "$((total - failed)) of $total runs succeeded. Results: $out"
[[ $failed -eq 0 ]]
