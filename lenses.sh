#!/usr/bin/env bash
# Run every lens once against a repo, on Claude, Codex or both.
#
# Usage: lenses.sh <repo-dir> <claude|codex|both>
#
# Writes <repo-dir>/audit/lenses/<timestamp>/<provider>/<lens>.md, a <lens>.log
# next to each, run.txt describing the run and listing each run's status, and
# coverage.txt listing which files the runs read.
# A run that fails, is stopped by a safeguard or doesn't read as a report
# leaves only its .log, so the check never reads an error message or a
# refusal as a report.
set -euo pipefail

MODEL="${SENTINEL_MODEL:-opus}"
EFFORT="${SENTINEL_EFFORT:-xhigh}"
# Set here because with an API key Codex runs with an empty CODEX_HOME and never
# reads ~/.codex/config.toml. SENTINEL_CODEX_MODEL="" uses Codex's own default.
CODEX_MODEL="${SENTINEL_CODEX_MODEL-gpt-6-astra}"
CODEX_EFFORT="${SENTINEL_CODEX_EFFORT:-xhigh}"
RUN_TIMEOUT="${SENTINEL_RUN_TIMEOUT:-3600}"   # seconds per run
CLAUDE_PARALLEL=3
CODEX_PARALLEL=4

die() { echo "lenses.sh: $*" >&2; exit 2; }

[[ $# -eq 2 ]] || die "usage: lenses.sh <repo-dir> <claude|codex|both>"
repo=$(realpath "$1")
case $2 in
    claude) providers=(claude) ;;
    codex) providers=(codex) ;;
    both) providers=(claude codex) ;;
    *) die "provider must be claude, codex or both" ;;
esac
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"
[[ -f $repo/THREAT-MODEL.md ]] || die "$repo/THREAT-MODEL.md is missing; fill in threat-model.template.md first"
for tool in git tar timeout "${providers[@]}"; do
    command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

# Codex runs each command through its own program, so the folder it is
# installed in has to be readable too. When codex sits in a shared folder
# (~/.local/bin, ~/.cargo/bin, /usr/bin and the like), the folder above holds
# other programs' files, ~/.cargo/credentials.toml among them, so only the
# binary's own folder is made readable. A folder that holds the home folder,
# or Codex's home with its login (auth.json), is never made readable either.
# Every path is compared after symlinks are resolved, so a symlinked home
# can't slip past.
holds() { [[ $2 == "$1" || $2 == "$1"/* ]]; }   # holds <folder> <path>
if [[ ${providers[*]} == *codex* ]]; then
    home_real=$(realpath "$HOME")
    codex_bin=$(dirname "$(realpath "$(command -v codex)")")
    codex_root=$(dirname "$codex_bin")
    case $codex_root in
        / | /usr | /usr/local | /opt | "$home_real"/.local | "$home_real"/.cargo) codex_root=$codex_bin ;;
    esac
    for guarded in "$home_real" "${CODEX_HOME:-}" "$HOME/.codex"; do
        [[ -n $guarded && -e $guarded ]] || continue
        guarded=$(realpath "$guarded")
        ! holds "$codex_root" "$guarded" || codex_root=$codex_bin
        ! holds "$codex_root" "$guarded" ||
            die "codex is installed in a folder that holds $guarded, your home folder or Codex's home with its login; install it somewhere else"
    done
fi

sentinel=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
lenses=("$sentinel"/lenses/*.md)
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$repo/audit/lenses/$ts"
mkdir -p "$out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Reviewers read a snapshot of the repo's tracked and untracked-but-not-ignored
# files, not the repo itself. Every run sees the same files, no run can read
# another run's output under audit/, and nothing a reviewer does can touch the
# real working tree. The kit itself is left out when it lives inside the repo,
# and so are /claude-security reports, so the lenses stay independent of the
# scan. They are named here as well as gitignored, in case the ignore lines
# are missing.
excludes=(":(exclude)audit" ":(exclude)CLAUDE-SECURITY-*")
rel=$(realpath --relative-to="$repo" "$sentinel")
[[ $rel == .. || $rel == ../* ]] || excludes+=(":(exclude)$rel")
# A submodule shows up in the first listing as one directory, and copying that
# directory whole would bring in files its own .gitignore excludes (.env,
# target/). So directories are never copied recursively; the files inside
# submodules come from the second listing, which names each tracked file.
mkdir "$work/repo"
{
    git -C "$repo" ls-files -z --cached --others --exclude-standard -- . "${excludes[@]}"
    git -C "$repo" ls-files -z --cached --recurse-submodules -- . "${excludes[@]}"
} | sort -zu |
    tar -c -f - -C "$repo" --null --no-recursion --ignore-failed-read -T - |
    tar -x -f - -C "$work/repo"
# A symlink still points wherever it pointed in the repo, so a reviewer that
# follows one could read a file outside the snapshot, a key under ~/.ssh for
# one. Every link is removed, and run.txt names them, with control characters
# stripped from the names so a crafted one can't drive the terminal.
links=$(cd "$work/repo" && find . -type l -printf '%P -> %l\0' |
    LC_ALL=C tr -d '\001-\037\177' | tr '\0' '\n')
find "$work/repo" -type l -delete
snapshot_files=$(find "$work/repo" -type f -printf '.' | wc -c)
mkdir "$work/reads"

# Claude: --safe-mode skips the user's and the repo's hooks, plugins, MCP
# servers and CLAUDE.md, and --setting-sources "" loads no settings file, so
# neither the repo's .claude/settings.json nor an allow rule in the user's own
# settings can widen what a reviewer reads. The tools are Read, Grep and Glob
# (--bare would drop Grep and Glob), nothing is pre-approved, so any read or
# search outside the snapshot is refused. With an API key set, the key is
# billed; without one, the logged-in plan is.
# SENTINEL_ANTHROPIC_API_KEY lets the key live in a shell profile without
# every interactive Claude Code session picking it up as ANTHROPIC_API_KEY.
claude_key="${SENTINEL_ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY:-}}"
if [[ -n $claude_key ]]; then
    claude_auth="API key (SENTINEL_ANTHROPIC_API_KEY or ANTHROPIC_API_KEY)"
else
    claude_auth="logged-in Claude plan (no API key set)"
fi

# Codex: codex exec reads CODEX_API_KEY, not OPENAI_API_KEY, so pass the key
# under that name. With a key, CODEX_HOME is an empty directory so the user's
# global AGENTS.md and config stay out of the run. Without one, Codex uses its
# own login and loads them.
codex_key="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
if [[ -n $codex_key ]]; then
    codex_home="$work/codex-home"
    mkdir -m 700 "$codex_home"
    codex_auth="API key (CODEX_API_KEY or OPENAI_API_KEY)"
else
    codex_home="${CODEX_HOME:-$HOME/.codex}"
    codex_auth="existing Codex login (no API key set; global AGENTS.md will load)"
fi

{
    echo "repo: $repo"
    echo "commit: $(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    echo "uncommitted changes: $([[ -n $(git -C "$repo" status --porcelain -- . "${excludes[@]}") ]] && echo yes || echo no)"
    echo "sentinel commit: $(git -C "$sentinel" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    # The lenses judge against THREAT-MODEL.md, so record how current it was.
    tm_age=$("$sentinel/threat-model-age.sh" "$repo" || true)
    echo "threat model: ${tm_age%%$'\n'*}"
    # SENTINEL.md names the commit the previous audit covered.
    stamp_age=$("$sentinel/stamp-age.sh" "$repo" || true)
    echo "previous audit: ${stamp_age%%$'\n'*}"
    echo "started: $ts"
    echo "providers: ${providers[*]}"
    [[ ${providers[*]} != *claude* ]] || echo "claude: model $MODEL, effort $EFFORT, auth: $claude_auth"
    [[ ${providers[*]} != *codex* ]] || echo "codex: model ${CODEX_MODEL:-default}, effort $CODEX_EFFORT, web search off, reads limited to the snapshot, auth: $codex_auth"
    [[ ${providers[*]} != *codex* ]] || echo "codex readable install folder: $codex_root"
    echo "lenses: $(basename -s .md -a "${lenses[@]}" | tr '\n' ' ')"
    if [[ -n $links ]]; then
        echo "symlinks left out of the snapshot:"
        printf '%s\n' "$links" | sed 's/^/  /'
    else
        echo "symlinks left out of the snapshot: none"
    fi
} > "$out/run.txt"
cat "$out/run.txt"
echo

# Prints the run's line and adds it to run.txt, so the check in step 4 sees
# which runs were blocked, unreadable or answered by another model.
status() { # provider lens seconds result [note...]
    local secs=$3 line note
    line=$(printf '[%s] %-17s %s in %dm%02ds' "$1" "$2" "$4" $((secs / 60)) $((secs % 60)))
    shift 4
    for note; do line+="; $note"; done
    echo "$line"
    echo "$line" >> "$out/run.txt"
}

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

# finish <dest> <rc> [blocked] keeps the report only when the run succeeded,
# the reply didn't end in a refusal and it reads as a report. Anything else goes to the
# end of the .log and leaves no .md, so step 4 never reads it as a report.
# Sets result and adds to notes, both the caller's locals.
finish() {
    local problems line
    if [[ $2 -ne 0 ]]; then
        result="FAILED (exit $2, see ${1#"$out/"}.log)"
    elif [[ -n ${3:-} ]]; then
        result="BLOCKED (the reply ended in a refusal, see ${1#"$out/"}.log)"
    elif ! problems=$(check_report "$1.md.part"); then
        result="UNPARSEABLE (no findings and no 'No findings' block, see ${1#"$out/"}.log)"
    else
        mv "$1.md.part" "$1.md"
        result="ok"
        [[ -z $problems ]] || while IFS= read -r line; do notes+=("$line"); done <<< "$problems"
        return 0
    fi
    [[ ! -s $1.md.part ]] || cat "$1.md.part" >> "$1.log"
    rm -f "$1.md.part"
    return 1
}

# parse_run <claude|codex> <events> <dest> <lens> records the files the run
# read in $work/reads/<provider>-<lens> and prints the models that wrote
# output, "blocked" when the reply ended in a refusal, the number of files
# read in full, and the number of safety stops during the run, one per line. For Claude it also writes the reply to
# <dest>.md.part. lens-events.py says what counts as read.
parse_run() {
    python3 -I "$sentinel/lens-events.py" "$1" "$2" "$3" "$work/reads/$1-$4" "$work/repo"
}

run_claude() { # lens prompt
    local dest="$out/claude/$1" json="$work/claude-$1.jsonl" start=$SECONDS rc=0
    local result notes=() info models="" blocked="" nread=0 stops=0 m
    local envs=(-u OPENAI_API_KEY -u CODEX_API_KEY -u SENTINEL_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY)
    [[ -z $claude_key ]] || envs+=("ANTHROPIC_API_KEY=$claude_key")
    (cd "$work/repo" && env "${envs[@]}" \
        timeout --kill-after=30 "$RUN_TIMEOUT" \
        claude -p --safe-mode --model "$MODEL" --effort "$EFFORT" \
            --setting-sources "" --tools "Read,Grep,Glob" \
            --permission-mode dontAsk --no-session-persistence \
            --output-format stream-json --verbose \
        < "$2" > "$json" 2> "$dest.log") || rc=$?
    # The events record each file the run read, name the models that wrote
    # the reply and say whether a safeguard stopped it, which the text output
    # leaves out. They stay in the temp folder, so step 4 reads only the .md
    # reports.
    if [[ -s $json ]] && info=$(parse_run claude "$json" "$dest" "$1" 2>> "$dest.log"); then
        { read -r models || true; read -r blocked || true; read -r nread || true
          read -r stops || true; } <<< "$info"
    else
        tail -n 20 "$json" >> "$dest.log"
        [[ $rc -ne 0 ]] || rc=1
    fi
    notes+=("model ${models:-not reported}")
    # SENTINEL_MODEL can be an alias (opus) or a full name with a suffix
    # (claude-opus-5-5[1m]); the JSON has the full name with no suffix.
    for m in ${models//,/ }; do
        [[ $m == *"${MODEL%%\[*}"* ]] || { notes+=("MODEL DIFFERS (asked for $MODEL)"); break; }
    done
    finish "$dest" "$rc" "$blocked" || rc=1
    # A safeguard can stop one reply and the model carry on to a complete
    # report. The report is kept, and the note tells step 4 to say so.
    [[ $result != ok || $stops -eq 0 ]] || notes+=("SAFETY STOP during the run ($stops), report kept")
    counted claude "$1" "$nread"
    status claude "$1" $((SECONDS - start)) "$result" "${notes[@]}"
    return "$rc"
}

# counted <provider> <lens> <files read> adds the count to the run's notes
# when it made a report. A run that made none drops its list of reads, so
# coverage.txt counts only files some report was written from.
counted() {
    if [[ $result == ok ]]; then
        notes+=("read $3 of $snapshot_files files in full")
    else
        rm -f "$work/reads/$1-$2"
    fi
}

run_codex() { # lens prompt
    local dest="$out/codex/$1" events="$work/codex-$1.jsonl" start=$SECONDS rc=0
    local result notes=() info nread=0
    # Codex's --sandbox read-only lets the model's commands read the whole disk
    # (home directory, keys), and it silently overrides any permission profile,
    # so it is not used. The "audit" profile makes only the system directories
    # commands need and the snapshot readable, with no writes and no network.
    # inherit="core" passes the commands PATH, HOME and the like, never
    # CODEX_API_KEY or any other key. web_search="disabled" removes the hosted
    # search tool, which runs on OpenAI's side where the profile can't reach.
    # codex_root is the install folder chosen above.
    local args=(exec --cd "$work/repo" --skip-git-repo-check --ephemeral
                -c 'default_permissions="audit"'
                -c "permissions.audit.filesystem={\":minimal\"=\"read\", \":workspace_roots\"=\"read\", \"$codex_root\"=\"read\"}"
                -c 'shell_environment_policy.inherit="core"'
                -c 'web_search="disabled"'
                -c "model_reasoning_effort=$CODEX_EFFORT" -c project_doc_max_bytes=0
                --json -o "$dest.md.part")
    [[ -z $CODEX_MODEL ]] || args+=(-m "$CODEX_MODEL")
    local envs=(-u ANTHROPIC_API_KEY -u SENTINEL_ANTHROPIC_API_KEY -u OPENAI_API_KEY "CODEX_HOME=$codex_home")
    [[ -z $codex_key ]] || envs+=("CODEX_API_KEY=$codex_key")
    env "${envs[@]}" timeout --kill-after=30 "$RUN_TIMEOUT" codex "${args[@]}" - \
        < "$2" > "$events" 2> "$dest.log" || rc=$?
    # The events record each command the run ran, and parse_run copies any
    # error they hold into the .log. They name no model, so only the format
    # is checked.
    if [[ -s $events ]] && info=$(parse_run codex "$events" "$dest" "$1" 2>> "$dest.log"); then
        nread=$(sed -n 3p <<< "$info")
    fi
    finish "$dest" "$rc" || rc=1
    counted codex "$1" "$nread"
    status codex "$1" $((SECONDS - start)) "$result" "${notes[@]}"
    return "$rc"
}

for lens_file in "${lenses[@]}"; do
    lens=$(basename "$lens_file" .md)
    { cat "$lens_file"; echo; cat "$sentinel/finding-format.md"; } > "$work/$lens.prompt.md"
done

failed=0 total=0
for provider in "${providers[@]}"; do
    mkdir -p "$out/$provider"
    [[ $provider == claude ]] && limit=$CLAUDE_PARALLEL || limit=$CODEX_PARALLEL
    pids=()
    for lens_file in "${lenses[@]}"; do
        lens=$(basename "$lens_file" .md)
        "run_$provider" "$lens" "$work/$lens.prompt.md" &
        pids+=($!)
        total=$((total + 1))
        if (( ${#pids[@]} >= limit )); then
            wait "${pids[0]}" || failed=$((failed + 1))
            pids=("${pids[@]:1}")
        fi
    done
    for pid in "${pids[@]}"; do wait "$pid" || failed=$((failed + 1)); done
done

# coverage.txt lists the files in the snapshot no run with a report read,
# then those read only in part, then every file with the runs that read it.
# Step 4 decides which of them are production code.
python3 -I "$sentinel/lens-events.py" coverage "$work/repo" "$work/reads" "$out/coverage.txt"

echo
echo "$((total - failed)) of $total runs succeeded. Results: $out"
[[ $failed -eq 0 ]]
