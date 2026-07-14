#!/usr/bin/env bash
#
# pkg0 installer for Debian-ish Linux
# -----------------------------------
# Usage:   curl -fsSL https://github.com/martona/pkg0/releases/latest/download/install.sh | bash
# Source:  https://github.com/martona/pkg0
#
# Installs pkg0, the sidecar package manager for .debs published via GitHub
# Releases. pkg0 itself ships as a .deb, so this installer needs apt-get and
# dpkg — on anything else there is nothing for pkg0 to manage anyway. The
# postinst registers pkg0 into its own state with attestation required, so
# every future `pkg0 selfupdate` is Sigstore-verified; this first install is
# trust-on-first-use by design.

set -eu

BASE="https://github.com/martona/pkg0/releases/latest/download"

# ---- pretty, noisy output ---------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  esc=$(printf '\033')
  C_CYAN="${esc}[36m"; C_GREEN="${esc}[32m"; C_RED="${esc}[31m"; C_DIM="${esc}[90m"; C_RESET="${esc}[0m"
else
  C_CYAN=; C_GREEN=; C_RED=; C_DIM=; C_RESET=
fi
step() { printf '%s==>%s %s\n' "$C_CYAN"  "$C_RESET" "$1"; }
ok()   { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
note() { printf '    %s%s%s\n' "$C_DIM"   "$1" "$C_RESET"; }
die()  {
  printf '%sx%s   %s\n' "$C_RED" "$C_RESET" "$1" >&2
  printf '    %sManual install: grab pkg0_latest_all.deb from https://github.com/martona/pkg0/releases%s\n' "$C_DIM" "$C_RESET" >&2
  printf '    %sand run: sudo apt-get install ./pkg0_latest_all.deb%s\n' "$C_DIM" "$C_RESET" >&2
  exit 1
}

printf '\n  %spkg0%s - sidecar package manager for .debs on GitHub Releases\n' "$C_CYAN" "$C_RESET"
printf '  %shttps://github.com/martona/pkg0%s\n\n' "$C_DIM" "$C_RESET"

# ---- temp workspace + cleanup ----------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- run privileged commands whether or not we're already root -------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---- download helper (curl or wget) ----------------------------------------
download() { # url dest
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "Need curl or wget to download files."
  fi
}

# ---- 1. this has to be a dpkg/apt system ------------------------------------
step "Checking for apt-get and dpkg..."
if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
  die "pkg0 installs and updates .debs, so it needs a system with apt-get and dpkg."
fi
note "found"

# ---- 2. download the deb -----------------------------------------------------
file="pkg0_latest_all.deb"
pkg="$TMP/$file"
step "Downloading $file ..."
note "$BASE/$file"
download "$BASE/$file" "$pkg"
note "$(du -h "$pkg" | cut -f1) downloaded"

# ---- 3. install --------------------------------------------------------------
step "Installing with apt..."
# The deb is unsigned by design: integrity is via the Sigstore attestation the
# release pipeline verifies before publishing (and that pkg0 itself verifies on
# every selfupdate), not repo GPG. apt doesn't GPG-check local .debs, so no
# special flags are needed.
# Make the temp dir + package world-readable so apt's unprivileged _apt user can
# read them (otherwise apt prints a scary but harmless "couldn't be accessed"
# note and falls back to running the fetch as root anyway).
chmod a+rx "$TMP" 2>/dev/null || true
chmod a+r "$pkg" 2>/dev/null || true
# the VAR=val form survives sudo's env_reset (and works as a plain prefix as root)
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"

printf '\n'
if command -v pkg0 >/dev/null 2>&1; then
  ok "pkg0 installed: $(command -v pkg0)"
else
  ok "pkg0 installed."
fi

# ---- next steps -------------------------------------------------------------
printf '\n'
note "pkg0 registered itself with attestation required; future selfupdates are verified."
note "Next, install cosign so pkg0 can verify attestations:"
note "    sudo pkg0 install sigstore/cosign"
note "then try:"
note "    sudo pkg0 install <owner>/<repo>     # any repo releasing .debs"
note "    pkg0 list && sudo pkg0 update"
printf '\n'
