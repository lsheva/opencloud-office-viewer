#!/usr/bin/env sh
# Installs office-viewer into an OpenCloud instance.
#
#   curl -fsSL https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/scripts/install.sh | sh
#   sh install.sh --detect        # show the detected paths, change nothing
#
# Order of work: everything that needs no privileges happens first (download,
# unpack, validate, locate directories, fetch the CSP file). Only then does it
# plan the changes, show them, and ask for sudo once — and only if some target
# is not already writable. All privileged commands run from that single call.
#
# Environment:
#   APPS_DIR        override the detected apps directory
#   WITH_CSP=0      skip the CSP override (default: 1, installing it)
#   CSP_FILE        use this CSP file instead of downloading csp-override.yaml
#   CSP_TARGET      default /etc/opencloud/csp-override.yaml
#   DROPIN_PATH     default /etc/systemd/system/opencloud.service.d/csp.conf
#   NO_RESTART=1    do not restart the service
#   SUDO_CMD        privileged-command wrapper (default: sudo; empty = run directly)
set -eu

default_source=https://github.com/lsheva/opencloud-office-viewer/releases/latest/download/office-viewer.tar.gz
source_arg=${1:-$default_source}

apps_dir_override=${APPS_DIR:-}
with_csp=${WITH_CSP-1}
csp_source=${CSP_FILE:-https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/csp-override.yaml}
csp_target=${CSP_TARGET:-/etc/opencloud/csp-override.yaml}
dropin=${DROPIN_PATH:-/etc/systemd/system/opencloud.service.d/csp.conf}
sudo_cmd=${SUDO_CMD-sudo}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# Single-quote a value for the generated plan script.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

can_write_dir() {
  d=$1
  while [ ! -e "$d" ]; do
    parent=$(dirname "$d")
    [ "$parent" = "$d" ] && return 1
    d=$parent
  done
  [ -w "$d" ]
}

# --- detection (no privileges required) --------------------------------------
detect_apps_dir() {
  if [ -n "$apps_dir_override" ]; then
    printf '%s' "$apps_dir_override"
    return
  fi
  if [ -n "${WEB_ASSET_APPS_PATH:-}" ]; then
    printf '%s' "$WEB_ASSET_APPS_PATH"
    return
  fi

  existing=$(find /var/lib /srv /opt /data /mnt /home -maxdepth 6 -type d \
    -path '*/web/assets/apps' 2>/dev/null | head -1 || true)
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return
  fi

  printf '%s' "${OC_DATA_DIR:-/var/lib/opencloud}/web/assets/apps"
}

fetch() {
  url_or_path=$1
  target=$2
  case "$url_or_path" in
    http://* | https://*) curl -fsSL "$url_or_path" -o "$target" ;;
    *)
      if [ ! -f "$url_or_path" ]; then
        echo "no such file: $url_or_path" >&2
        exit 1
      fi
      cp "$url_or_path" "$target"
      ;;
  esac
}

# Releases ship both .tar.gz and .zip; sniff the magic bytes so either works and
# only the extractor actually needed has to be installed.
extract() {
  archive=$1
  dest=$2
  magic=$(od -An -tx1 -N2 "$archive" 2>/dev/null | tr -d ' \n')
  case "$magic" in
    1f8b*)
      command -v tar >/dev/null 2>&1 || {
        echo "tar is required for .tar.gz archives" >&2
        exit 1
      }
      mkdir -p "$dest"
      tar -xzf "$archive" -C "$dest"
      ;;
    504b*)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$dest"
      elif command -v busybox >/dev/null 2>&1; then
        mkdir -p "$dest"
        busybox unzip -q -o "$archive" -d "$dest"
      else
        echo "this archive is a zip but unzip is not installed." >&2
        echo "use the .tar.gz release asset instead, e.g.:" >&2
        echo "  $default_source" >&2
        exit 1
      fi
      ;;
    *)
      echo "unrecognised archive format ($magic)" >&2
      exit 1
      ;;
  esac
}

# --- 1. fetch ----------------------------------------------------------------
step "Downloading the release archive"
note "$source_arg"

workdir=$(mktemp -d 2>/dev/null || true)
if [ -z "${workdir:-}" ]; then
  # Some environments (busybox, odd TMPDIR) cannot create a temp dir; stay local.
  workdir="./.office-viewer-install.$$"
  mkdir -p "$workdir"
fi
keep_workdir=0
trap 'if [ "${keep_workdir:-0}" = 1 ]; then :; else rm -rf "$workdir"; fi' EXIT

fetch "$source_arg" "$workdir/app.archive"
note "saved to $workdir/app.archive"

# --- 2. unpack + validate ----------------------------------------------------
step "Unpacking and validating the bundle"
extract "$workdir/app.archive" "$workdir/extracted"

# Archives built by scripts/package.sh have a top-level office-viewer/ folder;
# accept a flat bundle (just manifest.json + js/ + assets/) as well.
bundle="$workdir/extracted/office-viewer"
if [ ! -f "$bundle/manifest.json" ]; then
  if [ -f "$workdir/extracted/manifest.json" ]; then
    bundle="$workdir/extracted"
  else
    echo "archive does not look like an office-viewer bundle (no manifest.json)" >&2
    exit 1
  fi
fi
version=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$bundle/manifest.json" | head -1)
files=$(find "$bundle" -type f | wc -l | tr -d ' ')
note "office-viewer ${version:-unknown}, $files files"
note "entrypoint: $(sed -n 's/^ *"entrypoint": *"\([^"]*\)".*/\1/p' "$bundle/manifest.json" | head -1)"

# --- 3. locate the target ----------------------------------------------------
step "Locating the OpenCloud apps directory"
apps_dir=$(detect_apps_dir)
note "$apps_dir"

if [ "${1:-}" = "--detect" ]; then
  printf '\n'
  note "csp file:  $csp_target"
  note "drop-in:   $dropin"
  exit 0
fi

# --- 4. prepare the CSP file (still unprivileged) ----------------------------
if [ "$with_csp" = "1" ]; then
  step "Preparing the CSP override"
  note "the renderer needs 'wasm-unsafe-eval' and blob: workers; OpenCloud's default policy allows neither"
  fetch "$csp_source" "$workdir/csp-override.yaml"
  note "staged at $workdir/csp-override.yaml"
fi

# --- 5. plan ---------------------------------------------------------------
step "Planning changes"
note "app:     $apps_dir/office-viewer"
[ "$with_csp" = "1" ] && note "csp:     $csp_target"
[ "$with_csp" = "1" ] && note "drop-in: $dropin"
if [ "${NO_RESTART:-}" != "1" ]; then
  note "restart: opencloud"
else
  note "restart: skipped (NO_RESTART=1)"
fi

plan="$workdir/apply.sh"
{
  printf 'mkdir -p %s\n' "$(q "$apps_dir/office-viewer")"
  printf 'cp -a %s/. %s\n' "$(q "$bundle")" "$(q "$apps_dir/office-viewer")"
  if [ "$with_csp" = "1" ]; then
    printf 'mkdir -p %s %s\n' "$(q "$(dirname "$csp_target")")" "$(q "$(dirname "$dropin")")"
    printf 'cp %s %s\n' "$(q "$workdir/csp-override.yaml")" "$(q "$csp_target")"
    printf "printf '[Service]\\\\nEnvironment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=%%s\\\\n' %s > %s\n" \
      "$(q "$csp_target")" "$(q "$dropin")"
  fi
  if [ "${NO_RESTART:-}" != "1" ]; then
    printf 'if command -v systemctl >/dev/null 2>&1; then\n'
    printf '  systemctl daemon-reload\n'
    printf '  systemctl restart opencloud 2>/dev/null || systemctl restart opencloud.service 2>/dev/null || true\n'
    printf 'fi\n'
  fi
} > "$plan"

# Does anything in the plan need root?
needs_root=""
if [ "$(id -u)" -ne 0 ] && [ -n "$sudo_cmd" ]; then
  if ! can_write_dir "$apps_dir"; then
    needs_root="write $apps_dir"
  fi
  if [ "$with_csp" = "1" ] && [ -z "$needs_root" ]; then
    if ! can_write_dir "$(dirname "$csp_target")" || ! can_write_dir "$(dirname "$dropin")"; then
      needs_root="write $csp_target and $dropin"
    fi
  fi
  if [ "${NO_RESTART:-}" != "1" ] && [ -z "$needs_root" ]; then
    needs_root="restart the service"
  fi
fi

# --- 6. apply ----------------------------------------------------------------
if [ -n "$needs_root" ]; then
  step "Applying changes (sudo)"
  note "needed to $needs_root"
  if ! command -v "$sudo_cmd" >/dev/null 2>&1 || ! "$sudo_cmd" -v; then
    keep_workdir=1
    printf '\n' >&2
    note "Could not get sudo. Everything is staged — finish with:" >&2
    note "  sudo sh '$plan'" >&2
    note "or re-run as root. Staged files stay in '$workdir'." >&2
    exit 1
  fi
  "$sudo_cmd" sh "$plan"
else
  step "Applying changes"
  note "no sudo needed: all target paths are writable"
  sh "$plan"
fi

note "app installed:  $apps_dir/office-viewer"
[ "$with_csp" = "1" ] && note "csp installed:  $csp_target"
if [ "${NO_RESTART:-}" = "1" ]; then
  note "not restarted — run: sudo systemctl restart opencloud"
fi

step "Done"
note "open 'office-viewer' from the app switcher; .docx/.xlsx/.pptx and legacy Office files render in the browser"
