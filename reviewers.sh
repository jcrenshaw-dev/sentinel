#!/usr/bin/env bash
# The snapshot and the two reviewers that lenses.sh and refute.sh share.
# Sourced, not run. Before sourcing, the script sets:
#   repo        the repo under review, from realpath
#   providers   array of claude, codex or both
# and after sourcing it sets out, the folder results go to, calls
# guard_codex, make_snapshot and set_keys, defines check_report <file>, which
# fails when the file is not a reply in the shape the script asked for and
# prints one line per block that is missing a field, and runs run_batch.
# This file sets work, a private temp folder removed on exit, with the
# snapshot in $work/repo, and the settings below from the environment.
# shellcheck disable=SC2154  # repo, providers and out are the caller's

# Everything these scripts write under audit/ holds unfixed findings, so no
# other user on the machine gets to read it.
umask 077

MODEL="${SENTINEL_MODEL:-opus}"
EFFORT="${SENTINEL_EFFORT:-xhigh}"
# Set here because with an API key Codex runs with an empty CODEX_HOME and never
# reads ~/.codex/config.toml. SENTINEL_CODEX_MODEL="" uses Codex's own default.
CODEX_MODEL="${SENTINEL_CODEX_MODEL-gpt-6-astra}"
CODEX_EFFORT="${SENTINEL_CODEX_EFFORT:-xhigh}"
RUN_TIMEOUT="${SENTINEL_RUN_TIMEOUT:-3600}"   # seconds per run
CLAUDE_PARALLEL=3
CODEX_PARALLEL=4

sentinel=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

die() { echo "$(basename "$0"): $*" >&2; exit 2; }

# check_tools dies when git, tar, timeout or a chosen provider is missing.
check_tools() {
    local tool
    for tool in git tar timeout "${providers[@]}"; do
        command -v "$tool" >/dev/null || die "$tool not found on PATH"
    done
}

# Codex runs each command through its own program, so the folder it is
# installed in has to be readable too. When codex sits in a shared folder
# (~/.local/bin, ~/.cargo/bin, /usr/bin and the like), the folder above holds
# other programs' files, ~/.cargo/credentials.toml among them, so only the
# binary's own folder is made readable. A folder that holds the home folder,
# or Codex's home with its login (auth.json), is never made readable either.
# Every path is compared after symlinks are resolved, so a symlinked home
# can't slip past. Sets codex_root.
holds() { [[ $2 == "$1" || $2 == "$1"/* ]]; }   # holds <folder> <path>
guard_codex() {
    codex_root=""
    [[ ${providers[*]} == *codex* ]] || return 0
    local home_real codex_bin guarded
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
}

# make_out <folder> creates the results folder, adding -2, -3 and so on when a
# run started in the same second already has that name, so two runs never
# share a run.txt. Sets out.
make_out() {
    local base=$1 n=1
    mkdir -p "$(dirname "$base")"
    out=$base
    until mkdir "$out" 2>/dev/null; do n=$((n + 1)); out="$base-$n"; done
}

# Reviewers read a snapshot of the repo's tracked and untracked-but-not-ignored
# files, not the repo itself. Every run sees the same files, no run can read
# another run's output under audit/, and nothing a reviewer does can touch the
# real working tree. The kit itself is left out when it lives inside the repo,
# and so are /claude-security reports, so the reviewers stay independent of the
# scan. They are named here as well as gitignored, in case the ignore lines
# are missing. Sets work, excludes, links, untracked and snapshot_files.
make_snapshot() {
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    excludes=(":(exclude)audit" ":(exclude)CLAUDE-SECURITY-*")
    local rel
    rel=$(realpath --relative-to="$repo" "$sentinel")
    [[ $rel == .. || $rel == ../* ]] || excludes+=(":(exclude)$rel")
    # A submodule shows up in the first listing as one directory, and copying
    # that directory whole would bring in files its own .gitignore excludes
    # (.env, target/). So directories are never copied recursively; the files
    # inside submodules come from the second listing, which names each
    # tracked file.
    mkdir "$work/repo"
    {
        git -C "$repo" ls-files -z --cached --others --exclude-standard -- . "${excludes[@]}"
        git -C "$repo" ls-files -z --cached --recurse-submodules -- . "${excludes[@]}"
    } | sort -zu |
        tar -c -f - -C "$repo" --null --no-recursion --ignore-failed-read -T - |
        tar -x -f - -C "$work/repo"
    # A symlink still points wherever it pointed in the repo, so a reviewer
    # that follows one could read a file outside the snapshot, a key under
    # ~/.ssh for one. Every link is removed, and run.txt names them, with
    # control characters stripped from the names so a crafted one can't drive
    # the terminal.
    links=$(cd "$work/repo" && find . -type l -printf '%P -> %l\0' |
        LC_ALL=C tr -d '\001-\037\177' | tr '\0' '\n')
    find "$work/repo" -type l -delete
    # The untracked files that went in, so run.txt says what left the machine
    # when the reviewer runs on someone else's servers. Control characters are
    # stripped as above.
    untracked=$(git -C "$repo" ls-files -z --others --exclude-standard -- . "${excludes[@]}" |
        LC_ALL=C tr -d '\001-\037\177' | tr '\0' '\n')
    snapshot_files=$(find "$work/repo" -type f -printf '.' | wc -c)
    mkdir "$work/reads"
}

# Claude: --safe-mode skips the user's and the repo's hooks, plugins, MCP
# servers and CLAUDE.md, and --setting-sources "" loads no settings file, so
# neither the repo's .claude/settings.json nor an allow rule in the user's own
# settings can widen what a reviewer reads. The tools are Read, Grep and Glob
# (--bare would drop Grep and Glob), nothing is pre-approved, so any read or
# search outside the snapshot is refused. With an API key set, the key is
# billed; without one, the logged-in plan is.
# SENTINEL_ANTHROPIC_API_KEY lets the key live in a shell profile without
# every interactive Claude Code session picking it up as ANTHROPIC_API_KEY.
# Codex: codex exec reads CODEX_API_KEY, not OPENAI_API_KEY, so pass the key
# under that name. With a key, CODEX_HOME is an empty directory so the user's
# global AGENTS.md and config stay out of the run. Without one, Codex uses its
# own login and loads them. Sets claude_key, claude_auth, codex_key,
# codex_home and codex_auth.
set_keys() {
    claude_key="${SENTINEL_ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY:-}}"
    if [[ -n $claude_key ]]; then
        claude_auth="API key (SENTINEL_ANTHROPIC_API_KEY or ANTHROPIC_API_KEY)"
    else
        claude_auth="logged-in Claude plan (no API key set)"
    fi
    codex_key="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
    if [[ -n $codex_key ]]; then
        codex_home="$work/codex-home"
        mkdir -m 700 "$codex_home"
        codex_auth="API key (CODEX_API_KEY or OPENAI_API_KEY)"
    else
        codex_home="${CODEX_HOME:-$HOME/.codex}"
        codex_auth="existing Codex login (no API key set; global AGENTS.md will load)"
    fi
}

# run_header <timestamp> prints the lines of run.txt both scripts share.
run_header() {
    local tm_age stamp_age
    echo "repo: $repo"
    echo "commit: $(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    echo "uncommitted changes: $([[ -n $(git -C "$repo" status --porcelain -- . "${excludes[@]}") ]] && echo yes || echo no)"
    echo "sentinel commit: $(git -C "$sentinel" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    # The reviewers judge against THREAT-MODEL.md, so record how current it was.
    tm_age=$("$sentinel/threat-model-age.sh" "$repo" || true)
    echo "threat model: ${tm_age%%$'\n'*}"
    # SENTINEL.md names the commit the previous audit covered.
    stamp_age=$("$sentinel/stamp-age.sh" "$repo" || true)
    echo "previous audit: ${stamp_age%%$'\n'*}"
    echo "started: $1"
    echo "providers: ${providers[*]}"
    [[ ${providers[*]} != *claude* ]] || echo "claude: model $MODEL, effort $EFFORT, auth: $claude_auth"
    [[ ${providers[*]} != *codex* ]] || echo "codex: model ${CODEX_MODEL:-default}, effort $CODEX_EFFORT, web search off, reads limited to the snapshot, auth: $codex_auth"
    [[ ${providers[*]} != *codex* ]] || echo "codex readable install folder: $codex_root"
    if [[ -n $links ]]; then
        echo "symlinks left out of the snapshot:"
        printf '%s\n' "$links" | sed 's/^/  /'
    else
        echo "symlinks left out of the snapshot: none"
    fi
    if [[ -n $untracked ]]; then
        echo "untracked files in the snapshot:"
        printf '%s\n' "$untracked" | sed 's/^/  /'
    else
        echo "untracked files in the snapshot: none"
    fi
}

# Prints the run's line and adds it to run.txt, so the check that reads the
# results sees which runs were blocked, unreadable or answered by another model.
status() { # provider name seconds result [note...]
    local secs=$3 line note
    line=$(printf '[%s] %-17s %s in %dm%02ds' "$1" "$2" "$4" $((secs / 60)) $((secs % 60)))
    shift 4
    for note; do line+="; $note"; done
    echo "$line"
    echo "$line" >> "$out/run.txt"
}

# finish <dest> <rc> [blocked] keeps the reply only when the run succeeded,
# the reply didn't end in a refusal and check_report accepts it. Anything else
# goes to the end of the .log and leaves no .md, so nothing reads it as a
# result. Sets result and adds to notes, both the caller's locals.
finish() {
    local problems line
    if [[ $2 -ne 0 ]]; then
        result="FAILED (exit $2, see ${1#"$out/"}.log)"
    elif [[ -n ${3:-} ]]; then
        result="BLOCKED (the reply ended in a refusal, see ${1#"$out/"}.log)"
    elif ! problems=$(check_report "$1.md.part"); then
        result="UNPARSEABLE (the reply is not in the shape asked for, see ${1#"$out/"}.log)"
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

# parse_run <claude|codex> <events> <dest> <name> records the files the run
# read in $work/reads/<provider>-<name> and prints the models that wrote
# output, "blocked" when the reply ended in a refusal, the number of files
# read in full, and the number of safety stops during the run, one per line.
# For Claude it also writes the reply to <dest>.md.part. lens-events.py says
# what counts as read.
parse_run() {
    python3 -I "$sentinel/lens-events.py" "$1" "$2" "$3" "$work/reads/$1-$4" "$work/repo"
}

run_claude() { # name prompt
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
    # leaves out. They stay in the temp folder, so only the .md replies are
    # read afterwards.
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
    # reply. The reply is kept, and the note says so.
    [[ $result != ok || $stops -eq 0 ]] || notes+=("SAFETY STOP during the run ($stops), reply kept")
    counted claude "$1" "$nread"
    status claude "$1" $((SECONDS - start)) "$result" "${notes[@]}"
    return "$rc"
}

# counted <provider> <name> <files read> adds the count to the run's notes
# when it made a reply. A run that made none drops its list of reads, so
# coverage.txt counts only files some reply was written from.
counted() {
    if [[ $result == ok ]]; then
        notes+=("read $3 of $snapshot_files files in full")
    else
        rm -f "$work/reads/$1-$2"
    fi
}

run_codex() { # name prompt
    local dest="$out/codex/$1" events="$work/codex-$1.jsonl" start=$SECONDS rc=0
    local result notes=() info nread=0
    # Codex's --sandbox read-only lets the model's commands read the whole disk
    # (home directory, keys), and it silently overrides any permission profile,
    # so it is not used. The "audit" profile makes only the system directories
    # commands need and the snapshot readable, with no writes and no network.
    # inherit="core" passes the commands PATH, HOME and the like, never
    # CODEX_API_KEY or any other key. web_search="disabled" removes the hosted
    # search tool, which runs on OpenAI's side where the profile can't reach.
    # codex_root is the install folder guard_codex chose.
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
    # error they hold into the .log. They name no model, so only the shape of
    # the reply is checked.
    if [[ -s $events ]] && info=$(parse_run codex "$events" "$dest" "$1" 2>> "$dest.log"); then
        nread=$(sed -n 3p <<< "$info")
    fi
    finish "$dest" "$rc" || rc=1
    counted codex "$1" "$nread"
    status codex "$1" $((SECONDS - start)) "$result" "${notes[@]}"
    return "$rc"
}

# run_batch <provider> <name>... runs run_<provider> on each name's prompt,
# $work/<name>.prompt.md, CLAUDE_PARALLEL or CODEX_PARALLEL at a time, and
# adds to the caller's total and failed.
run_batch() {
    local provider=$1 limit pids=() name pid
    shift
    mkdir -p "$out/$provider"
    [[ $provider == claude ]] && limit=$CLAUDE_PARALLEL || limit=$CODEX_PARALLEL
    for name; do
        "run_$provider" "$name" "$work/$name.prompt.md" &
        pids+=($!)
        total=$((total + 1))
        if (( ${#pids[@]} >= limit )); then
            wait "${pids[0]}" || failed=$((failed + 1))
            pids=("${pids[@]:1}")
        fi
    done
    for pid in "${pids[@]}"; do wait "$pid" || failed=$((failed + 1)); done
}
