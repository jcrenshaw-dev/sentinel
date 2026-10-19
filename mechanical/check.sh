#!/usr/bin/env bash
# Run the mechanical security checks that apply to a repo.
#
# Usage: check.sh [repo-dir=.]
#   SENTINEL_FUZZ_SECONDS=<n> also runs each fuzz target for n seconds.
#
# Gates (a failure, or the tool missing, makes the exit code non-zero):
#   cargo audit, cargo deny, cargo clippy, semgrep
# Reported only (output shown, exit code ignored):
#   cargo geiger, cargo vet, cargo fuzz build, cargo fuzz run (only when
#   SENTINEL_FUZZ_SECONDS is set), cargo miri test (only when the repo has
#   unsafe code and nightly has Miri), gitleaks, npm audit, pip-audit, bandit
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
    fuzz_run() {
        local rc=0 d t targets stamp log
        for d in "${fuzz_dirs[@]}"; do
            targets=$(cd "$d" && cargo +nightly fuzz list) || { rc=1; continue; }
            while IFS= read -r t; do
                [[ -n $t ]] || continue
                echo "-- $d/fuzz $t"
                # Artifacts newer than this file are the ones this run wrote.
                stamp=$(mktemp)
                log=$(mktemp)
                # On a crash, libFuzzer prints the input and cargo fuzz prints
                # its Debug form, so the output goes to a temp file and only
                # the lines that say what happened are shown.
                (cd "$d" && cargo +nightly fuzz run "$t" -- -max_total_time="$SENTINEL_FUZZ_SECONDS") \
                    > "$log" 2>&1 || rc=$?
                grep -E '^(Done [0-9]+ runs|SUMMARY: |Error: |error(\[E[0-9]+\])?: )' "$log"
                find "$d/fuzz/artifacts/$t" -type f -newer "$stamp" 2>/dev/null | sed 's/^/artifact: /'
                rm -f "$stamp" "$log"
            done <<< "$targets"
        done
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
        else
            step report "cargo fuzz run (${SENTINEL_FUZZ_SECONDS}s per target)" "$(cargo_sub fuzz)" fuzz_run
        fi
    else
        skip "cargo fuzz build and run" "no fuzz/ directory at the root or in any workspace member"
    fi

    # Miri checks unsafe code for undefined behavior, so it runs only when the
    # repo's own Rust code has an unsafe block, fn, impl, trait or extern.
    if grep -rqE --include='*.rs' --exclude-dir=target --exclude-dir=.git \
        --exclude-dir=vendor --exclude-dir=third_party \
        'unsafe[[:space:]]*(\{|fn|impl|trait|extern)' .; then
        # rustup puts a cargo-miri proxy on PATH for every toolchain, so ask
        # nightly itself whether Miri is installed (CI runners leave it out).
        if rustup +nightly component list --installed 2>/dev/null | grep -q '^miri'; then
            step report "cargo miri test" "$(cargo_sub miri)" cargo +nightly miri test --workspace --lib --bins
        else
            skip "cargo miri test" "Miri is not installed for nightly; rustup +nightly component add miri rust-src"
        fi
    else
        skip "cargo miri test" "no unsafe code in the repo's own Rust files"
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
