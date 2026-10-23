#!/usr/bin/env bash
# Install the tools check.sh runs, on Arch Linux.
#
# pacman needs root and runs through sudo. The cargo tools install into
# $CARGO_HOME/bin (~/.cargo/bin by default) with cargo install, and semgrep,
# pip-audit and zizmor install into ~/.local/bin with pipx; neither needs
# root.
set -euo pipefail

command -v pacman >/dev/null || { echo "install.sh: this script is for Arch Linux (pacman not found)" >&2; exit 2; }

pkgs=(base-devel git openssl pkgconf python python-pipx nodejs npm gitleaks shellcheck)
# Leave an existing rustup alone, including one installed with rustup-init.
# pacman's rustup conflicts with the rust package; if rust is installed,
# pacman asks whether to replace it.
command -v rustup >/dev/null || pkgs+=(rustup)
sudo pacman -S --needed "${pkgs[@]}"

# cargo fuzz and Miri need nightly.
rustup update stable
rustup default >/dev/null 2>&1 || rustup default stable
rustup component add clippy --toolchain stable
rustup toolchain install nightly --profile minimal
rustup component add miri --toolchain nightly

cargo install --locked cargo-deny cargo-vet cargo-fuzz cargo-nextest

for pkg in semgrep pip-audit zizmor; do
    if pipx list --short 2>/dev/null | grep -q "^$pkg "; then
        pipx upgrade "$pkg"
    else
        pipx install "$pkg"
    fi
done
pipx ensurepath

echo
echo "Installed. If ${CARGO_HOME:-~/.cargo}/bin or ~/.local/bin is new to your PATH, open a new shell before running check.sh."
