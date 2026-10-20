#!/usr/bin/env bash
# Install the tools check.sh runs on a Debian or Ubuntu CI runner. Run it from
# the root of the repo under audit. mechanical/install.sh is the Arch version
# for a workstation.
#
# Usage: install-tools.sh
#   The gating tools: cargo-audit, cargo-deny and clippy when the repo has a
#   Cargo.toml, and semgrep. Also gitleaks, shellcheck and zizmor, which
#   check.sh only reports.
#
# Works as root without sudo (Forgejo runner images) and as a normal user with
# sudo (GitHub runners). New PATH entries are written to $GITHUB_PATH, which
# both GitHub and Forgejo read.
set -euo pipefail

[[ $# -eq 0 ]] || { echo "usage: $(basename "$0")" >&2; exit 2; }

sudo=()
[[ $EUID -eq 0 ]] || sudo=(sudo)

"${sudo[@]}" apt-get update
"${sudo[@]}" apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev ca-certificates curl git python3 pipx

add_path() {
    export PATH="$1:$PATH"
    [[ -z ${GITHUB_PATH:-} ]] || echo "$1" >> "$GITHUB_PATH"
}
add_path "$HOME/.local/bin"

if [[ -f Cargo.toml ]]; then
    if ! command -v rustup >/dev/null; then
        # GitHub's runners already have rustup; this is for images that do not.
        # The installer's version and SHA-256 are pinned here, so a changed
        # file on the download server is refused instead of run.
        rustup_version=1.29.1
        case $(uname -m) in
            x86_64) target=x86_64-unknown-linux-gnu
                    sum=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71 ;;
            aarch64) target=aarch64-unknown-linux-gnu
                     sum=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433 ;;
            *) echo "install-tools.sh: no pinned rustup-init for $(uname -m)" >&2; exit 1 ;;
        esac
        init=$(mktemp)
        curl --proto '=https' --tlsv1.2 -sSf -o "$init" \
            "https://static.rust-lang.org/rustup/archive/$rustup_version/$target/rustup-init"
        echo "$sum  $init" | sha256sum -c --quiet -
        chmod +x "$init"
        "$init" -y --profile minimal
        rm -f "$init"
    fi
    add_path "$HOME/.cargo/bin"
    rustup toolchain install stable --profile minimal --component clippy
    # A repo that pins its toolchain builds, and so runs clippy, on that one,
    # and a minimal pinned profile leaves clippy out.
    pinned=""
    for f in rust-toolchain.toml rust-toolchain; do
        [[ -f $f ]] || continue
        pinned=$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -n 1)
        # The older rust-toolchain file may hold just the channel name.
        [[ -n $pinned || $f != rust-toolchain ]] || pinned=$(head -n 1 "$f" | tr -d '[:space:]')
        break
    done
    [[ -z $pinned ]] || rustup toolchain install "$pinned" --profile minimal --component clippy
    # Pinned so a new release can't change what the gates check. Bump the
    # versions here, from crates.io. A change to the RustSec database's format
    # can need a newer cargo-audit.
    cargo install --locked cargo-audit@0.22.2 cargo-deny@0.20.2
fi

# Pinned like the cargo tools; bump the version here, from PyPI.
pipx install semgrep==1.181.0

# gitleaks comes from its GitHub release instead of apt, so every runner gets
# the same version. Its version and SHA-256 are pinned here, like
# rustup-init's; bump them together, from the release's checksums file.
gitleaks_version=8.30.1
case $(uname -m) in
    x86_64) gitleaks_arch=x64
            sum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    aarch64) gitleaks_arch=arm64
             sum=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    *) echo "install-tools.sh: no pinned gitleaks for $(uname -m)" >&2; exit 1 ;;
esac
tarball=$(mktemp)
# GitHub serves release files through a redirect, hence -L.
curl --proto '=https' --tlsv1.2 -sSfL -o "$tarball" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$gitleaks_version/gitleaks_${gitleaks_version}_linux_$gitleaks_arch.tar.gz"
echo "$sum  $tarball" | sha256sum -c --quiet -
mkdir -p "$HOME/.local/bin"
tar -xzf "$tarball" -C "$HOME/.local/bin" gitleaks
rm -f "$tarball"

# The shellcheck binary is pinned the same way, from its static release
# build. The SHA-256 is the one GitHub records for the release file; bump the
# two together.
shellcheck_version=0.11.0
case $(uname -m) in
    x86_64) shellcheck_arch=x86_64
            sum=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6 ;;
    aarch64) shellcheck_arch=aarch64
             sum=68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc ;;
    *) echo "install-tools.sh: no pinned shellcheck for $(uname -m)" >&2; exit 1 ;;
esac
tarball=$(mktemp)
curl --proto '=https' --tlsv1.2 -sSfL -o "$tarball" \
    "https://github.com/koalaman/shellcheck/releases/download/v$shellcheck_version/shellcheck-v$shellcheck_version.linux.$shellcheck_arch.tar.gz"
echo "$sum  $tarball" | sha256sum -c --quiet -
tar -xzf "$tarball" -C "$HOME/.local/bin" --strip-components=1 "shellcheck-v$shellcheck_version/shellcheck"
rm -f "$tarball"

# Pinned like semgrep; bump the version here, from PyPI.
pipx install zizmor==1.30.1
