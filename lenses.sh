#!/usr/bin/env bash
# Run every lens once against a repo, on Claude, Codex or both.
#
# Usage: lenses.sh <repo-dir> <claude|codex|both>
#   SENTINEL_LENSES=<name>,<name> runs only those lenses.
#
# Writes <repo-dir>/audit/lenses/<timestamp>/<provider>/<lens>.md, a <lens>.log
# next to each, run.txt describing the run and listing each run's status, and
# coverage.txt listing which files the runs read.
# A run that fails, is stopped by a safeguard or doesn't read as a report
# leaves only its .log, so the check never reads an error message or a
# refusal as a report. The snapshot, the sandboxes and the reviewers are in
# reviewers.sh, shared with refute.sh.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: lenses.sh <repo-dir> <claude|codex|both>" >&2; exit 2; }
repo=$(realpath "$1")
case $2 in
    claude) providers=(claude) ;;
    codex) providers=(codex) ;;
    both) providers=(claude codex) ;;
    *) echo "lenses.sh: provider must be claude, codex or both" >&2; exit 2 ;;
esac

# shellcheck source=reviewers.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/reviewers.sh"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"
[[ -f $repo/THREAT-MODEL.md ]] || die "$repo/THREAT-MODEL.md is missing; fill in threat-model.template.md first"
check_tools
guard_codex

# SENTINEL_LENSES names a subset, comma separated, to rerun a lens whose run
# failed or was refused without paying for all eight.
lenses=()
if [[ -n ${SENTINEL_LENSES:-} ]]; then
    IFS=, read -r -a chosen <<< "$SENTINEL_LENSES"
    for lens in "${chosen[@]}"; do
        lens=${lens// /}
        [[ -n $lens ]] || continue
        [[ -f $sentinel/lenses/$lens.md ]] || die "no lens named $lens in $sentinel/lenses"
        lenses+=("$sentinel/lenses/$lens.md")
    done
    [[ ${#lenses[@]} -gt 0 ]] || die "SENTINEL_LENSES names no lens"
else
    lenses=("$sentinel"/lenses/*.md)
fi
ts=$(date -u +%Y%m%dT%H%M%SZ)
make_out "$repo/audit/lenses/$ts"
make_snapshot
set_keys

{
    run_header "$ts"
    echo "lenses: $(basename -s .md -a "${lenses[@]}" | tr '\n' ' ')"
} > "$out/run.txt"
cat "$out/run.txt"
echo

# check_report <file> fails when the file is not a report in the shape
# finding-format.md asks for: no "## Finding:" block, and no "## No findings"
# block with an examined list. A refusal or a reply that ignored the format
# would otherwise reach step 4 as "nothing found". It prints one line for
# each finding block that is missing a field, by number only, since the
# titles are model output.
check_report() {
    awk 'BEGIN { split("location severity trigger consequence related", fields, " ") }
         function close_block(   i, m) {
             if (!in_block) return
             m = ""
             for (i = 1; i <= 5; i++) if (!(fields[i] in seen)) m = m (m == "" ? "" : ", ") fields[i]
             if (m != "") print "finding " n " is missing " m
             in_block = 0
         }
         /^```/ { fence = !fence; next }
         fence { next }
         /^## Finding:/ { close_block(); n++; in_block = 1; no_findings = 0; split("", seen); found = 1; next }
         /^## No findings/ { close_block(); no_findings = 1; next }
         /^## / { close_block(); no_findings = 0; next }
         { line = tolower($0) }
         in_block && match(line, /^[-*][[:space:]]*`?[a-z]+`?[[:space:]]*:/) {
             f = substr(line, 1, RLENGTH); gsub(/[^a-z]/, "", f); seen[f] = 1
         }
         no_findings && line ~ /^[-*][[:space:]]*`?examined`?[[:space:]]*:/ { examined = 1 }
         END { close_block(); exit !(found || examined) }' "$1"
}

names=()
for lens_file in "${lenses[@]}"; do
    lens=$(basename "$lens_file" .md)
    names+=("$lens")
    { cat "$lens_file"; echo; cat "$sentinel/finding-format.md"; } > "$work/$lens.prompt.md"
done

failed=0 total=0
for provider in "${providers[@]}"; do
    run_batch "$provider" "${names[@]}"
done

# coverage.txt lists the files in the snapshot no run with a report read,
# then those read only in part, then every file with the runs that read it.
# Step 4 decides which of them are production code.
python3 -I "$sentinel/lens-events.py" coverage "$work/repo" "$work/reads" "$out/coverage.txt"

echo
echo "$((total - failed)) of $total runs succeeded. Results: $out"
[[ $failed -eq 0 ]]
