#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - Bootstrap Installer (get.sh)
#
# Downloads the latest CLP Helper source from GitHub into a temporary
# directory, runs install.sh, and removes the temporary files afterwards.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yogoeasy/clp-helper/main/get.sh -o clp-get.sh && sudo bash clp-get.sh
#   wget -qO clp-get.sh https://raw.githubusercontent.com/yogoeasy/clp-helper/main/get.sh && sudo bash clp-get.sh
#
# Any arguments are passed to install.sh, for example:
#   sudo bash clp-get.sh --lang=zh_TW
#
# Environment variables:
#   CLP_REF   Branch or tag to install (default: main), e.g. CLP_REF=v1.0.0
# ==============================================================================
set -euo pipefail

CLP_REPO="yogoeasy/clp-helper"
CLP_REF="${CLP_REF:-main}"

msg() { printf '%s\n' "$*" >&2; }
die() { msg "[ERROR] $*"; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Please run as root: sudo bash $0 $*"
fi

if [[ ! "$CLP_REF" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die "Invalid CLP_REF: ${CLP_REF}"
fi

command -v tar >/dev/null 2>&1 || die "'tar' is required but not installed."

case "$CLP_REF" in
  v[0-9]*) archive_url="https://github.com/${CLP_REPO}/archive/refs/tags/${CLP_REF}.tar.gz" ;;
  *)       archive_url="https://github.com/${CLP_REPO}/archive/refs/heads/${CLP_REF}.tar.gz" ;;
esac

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/clp-get.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

msg "Downloading CLP Helper (${CLP_REF}) from GitHub ..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 15 --max-time 300 "$archive_url" -o "${work_dir}/src.tar.gz" \
    || die "Download failed: ${archive_url}"
elif command -v wget >/dev/null 2>&1; then
  wget -q --timeout=30 -O "${work_dir}/src.tar.gz" "$archive_url" \
    || die "Download failed: ${archive_url}"
else
  die "Either 'curl' or 'wget' is required."
fi

mkdir -p "${work_dir}/src"
tar -xzf "${work_dir}/src.tar.gz" -C "${work_dir}/src" --strip-components=1 \
  || die "Failed to extract the downloaded archive."

[[ -f "${work_dir}/src/install.sh" ]] || die "install.sh not found in the downloaded archive."

CLP_BOOTSTRAP=1 bash "${work_dir}/src/install.sh" "$@"
