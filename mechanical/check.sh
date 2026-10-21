#!/usr/bin/env bash
# Run the mechanical security checks that apply to a repo.
#
# Usage: check.sh [repo-dir=.]
#   SENTINEL_FUZZ_SECONDS=<n> also runs each fuzz target for n seconds.
#   SENTINEL_FUZZ_JOBS=<n> runs n fuzz targets at a time (default 1).
#
# Gates (a failure, or the tool missing, makes the exit code non-zero):
#   cargo audit, cargo deny, cargo clippy, semgrep (with the rules in the
#   repo's .semgrep/ folder, and their tests)
# Reported only (output shown, exit code ignored):
#   cargo geiger, cargo vet, cargo fuzz build, cargo fuzz run (only when
#   SENTINEL_FUZZ_SECONDS is set), cargo miri nextest run (only when the
#   repo has unsafe code and nightly has Miri), gitleaks, shellcheck, zizmor,
#   npm audit, pip-audit, bandit
set -uo pipefail

mech=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
repo=$(realpath "${1:-.}")
[[ -d $repo ]] || { echo "check.sh: $repo is not a directory" >&2; exit 2; }
cd "$repo" || exit 2

summary=()
gate_failed=0

# step gate|report <name> <tool> <command...>
step() {
    local kind=$1 name=$2 tool=$3
    shift 3
    echo
    echo "==> $name"
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found; see mechanical/install.sh"
        if [[ $kind == gate ]]; then
            summary+=("FAIL     $name (not installed)")
            gate_failed=1
        else
            summary+=("MISSING  $name (not installed)")
        fi
        return
    fi
    local rc=0
    "$@" || rc=$?
    if [[ $kind == gate ]]; then
        if [[ $rc -eq 0 ]]; then
            summary+=("PASS     $name")
        else
            summary+=("FAIL     $name (exit $rc)")
            gate_failed=1
        fi
    else
        summary+=("REPORT   $name (exit $rc)")
    fi
}

skip() { summary+=("SKIPPED  $1 ($2)"); }

# cargo subcommands are separate binaries, so check for those by name.
cargo_sub() { command -v "cargo-$1" >/dev/null && echo cargo || echo "cargo-$1"; }

# tracked [pathspec...] prints, NUL-separated, the tracked regular files that
# match, each starting with ./ so no file name reads as an option. Symlinks
# and files that resolve outside the repo are left out: both linters below
# print the lines they can't parse or complain about, so a link to a file
# elsewhere (a key, /proc/self/environ) would put that file in the output,
# and on CI in a public log.
tracked() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local f
    while IFS= read -r -d '' f; do
        [[ -f $f && ! -L $f && $(realpath -- "$f") == "$repo"/* ]] && printf './%s\0' "$f"
    done < <(git ls-files -z -- "$@")
    return 0
}

if [[ -f Cargo.toml ]]; then
    deny_cfg="$repo/deny.toml"
    [[ -f $deny_cfg ]] || deny_cfg="$mech/deny.toml"
    step gate "cargo audit" "$(cargo_sub audit)" cargo audit
    step gate "cargo deny ($deny_cfg)" "$(cargo_sub deny)" \
        cargo deny --manifest-path Cargo.toml --config "$deny_cfg" check
    step gate "cargo clippy" "$(cargo_sub clippy)" \
        cargo clippy --all-targets -- -W clippy::pedantic -W clippy::nursery

    # Manifest paths of every workspace member (or the one package). Python
    # runs isolated (-I) so a json.py in the repo can't stand in for the
    # standard library's.
    members() {
        cargo metadata --no-deps --format-version 1 |
            python3 -I -c 'import json,sys; print("\n".join(p["manifest_path"] for p in json.load(sys.stdin)["packages"]))'
    }

    # cargo geiger cannot run on a virtual workspace manifest, so run it on
    # each workspace member.
    geiger() {
        local manifests rc=0 m
        manifests=$(members) || return 1
        while IFS= read -r m; do
            echo "-- $m"
            cargo geiger --manifest-path "$m" || rc=$?
        done <<< "$manifests"
        return "$rc"
    }
    step report "cargo geiger" "$(cargo_sub geiger)" geiger

    if [[ -d supply-chain ]]; then
        step report "cargo vet" "$(cargo_sub vet)" cargo vet --locked
    else
        skip "cargo vet" "no supply-chain/ directory; run cargo vet init to start"
    fi

    # fuzz/ can sit at the repo root or inside any workspace member.
    fuzz_dirs=()
    while IFS= read -r d; do
        [[ -f $d/fuzz/Cargo.toml ]] && fuzz_dirs+=("$d")
    done < <({ echo "$repo"; members 2>/dev/null | xargs -r -d '\n' -n1 dirname; } | sort -u)
    fuzz_build() {
        local rc=0 d
        for d in "${fuzz_dirs[@]}"; do
            echo "-- $d/fuzz"
            (cd "$d" && cargo +nightly fuzz build) || rc=$?
        done
        return "$rc"
    }
    # fuzz_one <dir> <target> <report> runs one target and writes what
    # happened to <report>, so targets running side by side don't mix their
    # lines.
    fuzz_one() {
        local d=$1 t=$2 stamp log rc=0
        # Artifacts newer than this file are the ones this run wrote.
        stamp=$(mktemp)
        log=$(mktemp)
        # On a crash, libFuzzer prints the input and cargo fuzz prints its
        # Debug form, so the output goes to a temp file and only the lines
        # that say what happened are shown.
        (cd "$d" && cargo +nightly fuzz run "$t" -- -max_total_time="$SENTINEL_FUZZ_SECONDS") \
            > "$log" 2>&1 || rc=$?
        {
            echo "-- $d/fuzz $t"
            grep -E '^(Done [0-9]+ runs|SUMMARY: |Error: |error(\[E[0-9]+\])?: )' "$log"
            find "$d/fuzz/artifacts/$t" -type f -newer "$stamp" 2>/dev/null | sed 's/^/artifact: /'
        } > "$3"
        rm -f "$stamp" "$log"
        return "$rc"
    }
    # Runs SENTINEL_FUZZ_JOBS targets at a time. The oldest run is always
    # the one waited for, so reports print in target order, each as soon as
    # its run and every run before it are done.
    fuzz_run() {
        local rc=0 d t targets reports n=0 pids=() ids=()
        reports=$(mktemp -d)
        # wait_oldest prints the oldest run's report once it finishes.
        wait_oldest() {
            wait "${pids[0]}" || rc=$?
            cat "$reports/${ids[0]}"
            pids=("${pids[@]:1}")
            ids=("${ids[@]:1}")
        }
        for d in "${fuzz_dirs[@]}"; do
            targets=$(cd "$d" && cargo +nightly fuzz list) || { rc=1; continue; }
            while IFS= read -r t; do
                [[ -n $t ]] || continue
                fuzz_one "$d" "$t" "$reports/$n" &
                pids+=($!)
                ids+=("$n")
                n=$((n + 1))
                (( ${#pids[@]} < SENTINEL_FUZZ_JOBS )) || wait_oldest
            done <<< "$targets"
        done
        while (( ${#pids[@]} > 0 )); do wait_oldest; done
        rm -rf "$reports"
        return "$rc"
    }
    if [[ ${#fuzz_dirs[@]} -gt 0 ]]; then
        step report "cargo fuzz build" "$(cargo_sub fuzz)" fuzz_build
        # Running the targets takes SENTINEL_FUZZ_SECONDS for each one, so it
        # happens only when that is set: /snt:audit sets it and CI does not.
        if [[ -z ${SENTINEL_FUZZ_SECONDS:-} ]]; then
            skip "cargo fuzz run" "SENTINEL_FUZZ_SECONDS is not set"
        elif [[ ! $SENTINEL_FUZZ_SECONDS =~ ^[1-9][0-9]*$ ]]; then
            skip "cargo fuzz run" "SENTINEL_FUZZ_SECONDS is not a whole number of seconds"
        elif [[ ! ${SENTINEL_FUZZ_JOBS:=1} =~ ^[1-9][0-9]*$ ]]; then
            skip "cargo fuzz run" "SENTINEL_FUZZ_JOBS is not a whole number"
        else
            at_once=""
            [[ $SENTINEL_FUZZ_JOBS -eq 1 ]] || at_once=", $SENTINEL_FUZZ_JOBS at a time"
            step report "cargo fuzz run (${SENTINEL_FUZZ_SECONDS}s per target$at_once)" "$(cargo_sub fuzz)" fuzz_run
        fi
    else
        skip "cargo fuzz build and run" "no fuzz/ directory at the root or in any workspace member"
    fi

    # Miri checks unsafe code for undefined behavior, so it runs only when the
    # repo's own Rust code has an unsafe block, fn, impl, trait or extern. Miri
    # stops a test process at the first thing it cannot run, such as a call
    # into C (SQLite) or starting a process, so nextest runs each test in its
    # own Miri process: such a test stops only itself, though a data race
    # between two tests goes unseen. With isolation off, tests can use temp
    # directories, the clock and the environment. miri-nextest.toml stops any
    # test after 5 minutes.
    if grep -rqE --include='*.rs' --exclude-dir=target --exclude-dir=.git \
        --exclude-dir=vendor --exclude-dir=third_party \
        'unsafe[[:space:]]*(\{|fn|impl|trait|extern)' .; then
        # rustup puts a cargo-miri proxy on PATH for every toolchain, so ask
        # nightly itself whether Miri is installed (CI runners leave it out).
        if rustup +nightly component list --installed 2>/dev/null | grep -q '^miri'; then
            step report "cargo miri nextest run" "$(cargo_sub nextest)" \
                env MIRIFLAGS="${MIRIFLAGS:+$MIRIFLAGS }-Zmiri-disable-isolation" \
                cargo +nightly miri nextest run --workspace --lib --bins --no-fail-fast \
                --tool-config-file "sentinel:$mech/miri-nextest.toml"
        else
            skip "cargo miri nextest run" "Miri is not installed for nightly; rustup +nightly component add miri rust-src"
        fi
    else
        skip "cargo miri nextest run" "no unsafe code in the repo's own Rust files"
    fi
else
    skip "cargo checks" "no Cargo.toml"
fi

semgrep_args=(scan --metrics=off --error --exclude=audit)
while read -r section value; do
    case $section in
        configs)
            [[ $value == p/* || $value == r/* || $value == /* ]] || value="$mech/$value"
            semgrep_args+=(--config "$value") ;;
        exclude-rules)
            semgrep_args+=(--exclude-rule "$value") ;;
    esac
done < <(awk '/^[a-z-]+:/ { section = $1; sub(/:$/, "", section); next }
              /^[[:space:]]*-[[:space:]]*[^#[:space:]]/ { print section, $2 }' "$mech/semgrep.yml")

# A repo's own rules live in .semgrep/ and run with the kit's, each one
# written to keep a fixed finding fixed. A rule file is one that starts a
# top-level rules: list. Its test file has the same name with the target
# language's extension, and marks the pre-fix code with "ruleid: <id>" and the
# fixed code with "ok: <id>". The tests run first, so a rule that no longer
# matches its bug fails here instead of passing quietly, and so does a rule
# with no test file, which semgrep would otherwise pass. They run on a copy of
# the tracked regular files outside any dot folder, because semgrep --test
# skips dot folders, and so a symlink in .semgrep/ can't point the run at a
# file outside the repo.
repo_rules=() semgrep_files=()
while IFS= read -r -d '' f; do
    semgrep_files+=("$f")
    case $f in
        *.yml | *.yaml) ! grep -q '^rules:' "$f" || repo_rules+=("$f") ;;
    esac
done < <(tracked ':(glob).semgrep/**')
rule_tests() {
    local f g base tested rules_copy missing=0
    for f in "${repo_rules[@]}"; do
        base=${f%.*} tested=0
        for g in "${semgrep_files[@]}"; do
            [[ $g == "$base".* && $g != "$base.yml" && $g != "$base.yaml" ]] && { tested=1; break; }
        done
        [[ $tested -eq 1 ]] || { echo "$f has no test file named ${base#./}.<extension>"; missing=1; }
    done
    rules_copy=$(mktemp -d) || return 1
    for f in "${semgrep_files[@]}"; do
        mkdir -p "$rules_copy/rules/$(dirname "${f#./.semgrep/}")"
        cp -- "$f" "$rules_copy/rules/${f#./.semgrep/}"
    done
    semgrep --test --metrics=off "$rules_copy/rules" || missing=1
    rm -rf "$rules_copy"
    return "$missing"
}
semgrep_args+=(--exclude=.semgrep)
for f in "${repo_rules[@]}"; do semgrep_args+=(--config "$f"); done
if [[ ${#repo_rules[@]} -gt 0 ]]; then
    n=${#repo_rules[@]}
    step gate "semgrep rule tests ($n rule file$([[ $n -eq 1 ]] || echo s) in .semgrep)" semgrep rule_tests
fi
step gate "semgrep" semgrep semgrep "${semgrep_args[@]}" .

# semgrep's p/secrets sees only the working tree. gitleaks reads the diff of
# every commit on every ref, so a secret that was committed and later removed
# still shows.
gitleaks_history() {
    local report rc=0
    report=$(mktemp) || return 1
    # --redact covers gitleaks' output and its report. Debug logging prints
    # decoded secrets in the clear, so the level is pinned to info.
    gitleaks git --redact --no-banner --log-level info \
        --report-format json --report-path "$report" . || rc=$?
    # A finding's matched text can hold more than the one secret it redacts,
    # so print only each fingerprint (commit:file:rule:line), which is also
    # the form .gitleaksignore takes. Python runs isolated (-I) for the same
    # reason as in members().
    [[ ! -s $report ]] || python3 -I -c 'import json,sys; sys.stdout.write("".join("leak: " + f["Fingerprint"] + "\n" for f in json.load(open(sys.argv[1]))))' "$report"
    rm -f "$report"
    return "$rc"
}
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    step report "gitleaks (git history)" gitleaks gitleaks_history
else
    skip "gitleaks" "not a git repository"
fi

# Shell scripts are the tracked files named *.sh or *.bash and the tracked
# files whose first line runs sh or bash. zsh scripts are left out, since the
# linter can't read zsh. -S warning keeps style notes out of the report.
shell_files=()
while IFS= read -r -d '' f; do
    case $f in
        *.sh | *.bash) shell_files+=("$f") ;;
        *) [[ $(head -c 128 "$f" | head -n 1 | tr -d '\0') =~ ^#!.*[/[:space:]](ba)?sh([[:space:]]|$) ]] &&
               shell_files+=("$f") ;;
    esac
done < <(tracked)
if [[ ${#shell_files[@]} -gt 0 ]]; then
    step report "shellcheck (${#shell_files[@]} scripts)" shellcheck shellcheck -S warning "${shell_files[@]}"
else
    skip "shellcheck" "no tracked shell scripts"
fi

# zizmor gets the tracked workflow, composite action and dependabot.yml
# files by name, not the directory, so it never follows a link out of the
# repo. --offline keeps it off the network and away from any GitHub token in
# the environment.
zizmor_inputs=()
while IFS= read -r -d '' f; do zizmor_inputs+=("$f"); done < <(tracked \
    ':(glob).github/workflows/*.yml' ':(glob).github/workflows/*.yaml' \
    ':(glob).forgejo/workflows/*.yml' ':(glob).forgejo/workflows/*.yaml' \
    ':(glob).github/dependabot.yml' ':(glob).github/dependabot.yaml' \
    ':(glob)**/action.yml' ':(glob)**/action.yaml')
if [[ ${#zizmor_inputs[@]} -gt 0 ]]; then
    step report "zizmor" zizmor zizmor --offline --no-progress "${zizmor_inputs[@]}"
else
    skip "zizmor" "no tracked workflows, actions or dependabot.yml"
fi

if [[ -f package.json ]]; then
    if [[ -f package-lock.json ]]; then
        step report "npm audit" npm npm audit
    else
        skip "npm audit" "no package-lock.json; npm audit needs one"
    fi
else
    skip "npm audit" "no package.json"
fi

if [[ -f pyproject.toml || -f requirements.txt ]]; then
    # pip-audit takes a requirements file or a project path, not both, so a
    # repo with both gets one run for each.
    audited=0
    if [[ -f requirements.txt ]]; then
        step report "pip-audit (requirements.txt)" pip-audit pip-audit -r requirements.txt
        audited=1
    fi
    if grep -q '^\[project\]' pyproject.toml 2>/dev/null; then
        step report "pip-audit (pyproject.toml)" pip-audit pip-audit .
        audited=1
    fi
    [[ $audited -eq 1 ]] || skip "pip-audit" "pyproject.toml has no [project] table and there is no requirements.txt"
    step report "bandit" bandit bandit -r . \
        -x ./.git,./.venv,./venv,./node_modules,./target,./audit,./.tox,./__pycache__
else
    skip "pip-audit and bandit" "no pyproject.toml or requirements.txt"
fi

echo
echo "==> summary"
printf '%s\n' "${summary[@]}"
exit "$gate_failed"
