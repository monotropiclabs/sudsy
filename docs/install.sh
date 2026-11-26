#!/usr/bin/env bash
# Sudsy installer (MIT). macOS and Linux; Bash 3.2+.
# https://github.com/monotropiclabs/sudsy
# Keep execution inside main, called only at EOF, so a truncated curl pipe
# cannot run a partial installation.
set -euo pipefail

die() { printf 'sudsy: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Install Sudsy from a GitHub release, after checking its SHA-256.

Usage: bash install.sh [--version X.Y.Z] [--bin-dir /absolute/path]
  --version   Pin a release (vX.Y.Z also accepted; default: latest stable).
  --bin-dir   Install directory (default: ~/.local/bin).
  --help      Show this help.

Requires Bash, curl, SOPS and age. No sudo or Node.js required.
EOF
}

download() {
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 "$@"
}

main() {
  local tag="" bin_dir="$HOME/.local/bin" url effective expected filename actual
  local base="https://github.com/monotropiclabs/sudsy/releases"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || die "--version needs a value"
        tag="v${2#v}"; shift 2 ;;
      --bin-dir)
        [ "$#" -ge 2 ] || die "--bin-dir needs a path"
        bin_dir="$2"; shift 2 ;;
      -h|--help) usage; return ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  case "$(uname -s)" in Darwin|Linux) ;; *) die "macOS and Linux are supported" ;; esac
  case "$bin_dir" in /*) ;; *) die "--bin-dir must be an absolute path" ;; esac
  [ "$bin_dir" != / ] || die "choose a user-owned install directory"
  [ "$(id -u)" -ne 0 ] || die "run as your regular user, not root"
  command -v curl >/dev/null 2>&1 || die "install curl first"
  if ! command -v sops >/dev/null 2>&1 ||
     ! command -v age >/dev/null 2>&1 ||
     ! command -v age-keygen >/dev/null 2>&1; then
    die "install SOPS and age first (Homebrew: brew install sops age). See https://github.com/monotropiclabs/sudsy#install"
  fi

  if [ -z "$tag" ]; then
    effective="$(download -o /dev/null -w '%{url_effective}' "$base/latest")" ||
      die "could not find the latest release"
    case "$effective" in
      "$base/tag/"*) tag="${effective#"$base/tag/"}" ;;
      *) die "unexpected latest release URL" ;;
    esac
  fi
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "expected a stable release version, e.g. v0.2.0"
  url="$base/download/$tag"
  umask 077
  local work stage
  work="$(mktemp -d "${TMPDIR:-/tmp}/sudsy-install.XXXXXXXX")"
  # Use a subshell so cleanup can safely refer to its own local variables.
  (
    stage=""
    trap 'rm -rf -- "$work"; if [ -n "$stage" ]; then rm -f -- "$stage"; fi' EXIT
    download -o "$work/sudsy" "$url/sudsy" || die "could not download $tag"
    download -o "$work/sudsy.sha256" "$url/sudsy.sha256" || die "could not download checksum"
    read -r expected filename < "$work/sudsy.sha256" || die "invalid checksum file"
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] && [ "$filename" = sudsy ] ||
      die "invalid checksum file"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$work/sudsy")"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$work/sudsy")"
    else
      die "install sha256sum or shasum first"
    fi
    actual="${actual%% *}"
    [ "$actual" = "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ] || die "checksum mismatch; nothing installed"

    mkdir -p "$bin_dir"
    [ ! -L "$bin_dir/sudsy" ] && [ ! -d "$bin_dir/sudsy" ] ||
      die "refusing to replace a symlink or directory at $bin_dir/sudsy"
    # Stage in the destination directory so a failed download or write leaves
    # the old installation intact, then rename on the same filesystem.
    stage="$(mktemp "$bin_dir/.sudsy.XXXXXXXX")"
    install -m 755 "$work/sudsy" "$stage"
    mv -f -- "$stage" "$bin_dir/sudsy"
    stage=""
    say "Installed Sudsy $tag to $bin_dir/sudsy"
  )
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) say "Add $bin_dir to your PATH to run sudsy directly." ;;
  esac
}

main "$@"
