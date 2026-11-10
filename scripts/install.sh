#!/usr/bin/env sh
# Installs office-viewer into an OpenCloud instance.
#
#   curl -fsSL https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/scripts/install.sh | sh
#   sh install.sh --detect        # show the paths it would use, change nothing
#
# Everything that does not need privileges (download, unpack, validate, locate
# the apps directory) happens first. Only then does it ask for sudo — once — and
# it says what each sudo step is for.
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

default_source=https://github.com/lsheva/opencloud-office-viewer/releases/latest/download/office-viewer.zip
source_arg=${1:-$default_source}

apps_dir_override=${APPS_DIR:-}
with_csp=${WITH_CSP-1}
csp_source=${CSP_FILE:-https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/csp-override.yaml}
csp_target=${CSP_TARGET:-/etc/opencloud/csp-override.yaml}
dropin=${DROPIN_PATH:-/etc/systemd/system/opencloud.service.d/csp.conf}
sudo_cmd=${SUDO_CMD-sudo}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

as_root() {
  if [ "$(id -u)" -eq 0 ] || [ -z "$sudo_cmd" ]; then
    "$@"
  else
    "$sudo_cmd" "$@"
  fi
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

# Refinement that needs root: the running service knows its own data directory,
# which also works when no apps directory exists yet.
detect_apps_dir_from_service() {
  command -v systemctl >/dev/null 2>&1 || return 1
  pid=$(systemctl show -p MainPID --value opencloud 2>/dev/null || true)
  [ -n "${pid:-}" ] && [ "$pid" != "0" ] || return 1
  env_blob=$(as_root sh -c "tr '\0' '\n' < /proc/$pid/environ" 2>/dev/null) || return 1

  explicit=$(printf '%s\n' "$env_blob" | sed -n 's/^WEB_ASSET_APPS_PATH=//p' | head -1)
  [ -n "$explicit" ] && { printf '%s' "$explicit"; return 0; }

  for key in OC_DATA_DIR OC_BASE_DATA_PATH OCIS_BASE_DATA_PATH; do
    data_dir=$(printf '%s\n' "$env_blob" | sed -n "s/^$key=//p" | head -1)
    [ -n "$data_dir" ] && { printf '%s' "$data_dir/web/assets/apps"; return 0; }
  done
  return 1
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

manual_steps() {
  keep_workdir=1
  cat >&2 <<EOF
    To finish by hand, as root (the unpacked bundle is kept at '$bundle'):

      mkdir -p '$apps_dir'
      cp -a '$bundle/.' '$apps_dir/office-viewer/'

      # CSP override (required, otherwise nothing renders)
      curl -fsSL -o '$csp_target' '$csp_source'        # or copy csp-override.yaml
      mkdir -p '$(dirname "$dropin")'
      printf '[Service]\nEnvironment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=%s\n' '$csp_target' > '$dropin'
      systemctl daemon-reload
      systemctl restart opencloud

    Remove '$workdir' once done.
EOF
}

# --- 1. fetch ----------------------------------------------------------------
step "Downloading the release archive"
note "$source_arg"
if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required" >&2
  exit 1
fi

workdir=$(mktemp -d 2>/dev/null || true)
if [ -z "${workdir:-}" ]; then
  # Some environments (busybox, odd TMPDIR) cannot create a temp dir; stay local.
  workdir="./.office-viewer-install.$$"
  mkdir -p "$workdir"
fi
keep_workdir=0
trap 'if [ "${keep_workdir:-0}" = 1 ]; then :; else rm -rf "$workdir"; fi' EXIT

fetch "$source_arg" "$workdir/app.zip"
note "saved to $workdir/app.zip"

# --- 2. unpack + validate ----------------------------------------------------
step "Unpacking and validating the bundle"
unzip -q "$workdir/app.zip" -d "$workdir/extracted"

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
case "$apps_dir" in
  "$apps_dir_override") note "$apps_dir (APPS_DIR)" ;;
  *)
    if [ "$(id -u)" -eq 0 ] || [ -z "$sudo_cmd" ]; then
      note "$apps_dir"
    else
      note "$apps_dir (from the filesystem; confirmed with the service below)"
    fi
    ;;
esac

if [ "${1:-}" = "--detect" ]; then
  printf '\n'
  note "csp file:  $csp_target"
  note "drop-in:   $dropin"
  exit 0
fi

# --- 4. privileged steps -----------------------------------------------------
need_sudo=0
if [ "$(id -u)" -ne 0 ] && [ -n "$sudo_cmd" ]; then
  if command -v "$sudo_cmd" >/dev/null 2>&1; then
    need_sudo=1
  else
    step "Root privileges are required for the remaining steps"
    manual_steps
    exit 1
  fi
fi

if [ "$need_sudo" = "1" ]; then
  step "Requesting sudo"
  note "needed to write $apps_dir, add the CSP override and restart the service"
  if ! "$sudo_cmd" -v; then
    manual_steps
    exit 1
  fi

  refined=$(detect_apps_dir_from_service || true)
  if [ -n "${refined:-}" ] && [ "$refined" != "$apps_dir" ] && [ -z "$apps_dir_override" ]; then
    note "the service reports $refined — installing there instead"
    apps_dir=$refined
  fi
fi

step "Installing the app"
as_root mkdir -p "$apps_dir/office-viewer"
as_root cp -a "$bundle/." "$apps_dir/office-viewer/"
note "$apps_dir/office-viewer"

if [ "$with_csp" = "1" ]; then
  step "Installing the CSP override"
  note "the library needs 'wasm-unsafe-eval' and blob: workers; OpenCloud's default policy allows neither"
  fetch "$csp_source" "$workdir/csp-override.yaml"
  as_root mkdir -p "$(dirname "$csp_target")" "$(dirname "$dropin")"
  as_root cp "$workdir/csp-override.yaml" "$csp_target"
  printf '[Service]\nEnvironment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=%s\n' "$csp_target" \
    | as_root tee "$dropin" >/dev/null
  note "$csp_target"
  note "$dropin"
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl daemon-reload
  fi
else
  step "Skipping the CSP override (WITH_CSP=0)"
  note "without it the app loads but renders nothing"
fi

if [ "${NO_RESTART:-}" != "1" ]; then
  step "Restarting OpenCloud"
  note "app manifests are only read at startup"
  restarted=""
  if command -v systemctl >/dev/null 2>&1; then
    for unit in opencloud opencloud.service; do
      if as_root systemctl restart "$unit" 2>/dev/null; then
        restarted=$unit
        break
      fi
    done
  fi
  if [ -n "$restarted" ]; then
    note "$restarted restarted"
  else
    note "could not restart automatically — run: sudo systemctl restart opencloud"
  fi
else
  step "Not restarting (NO_RESTART=1)"
  note "run: sudo systemctl restart opencloud"
fi

step "Done"
note "open 'office-viewer' from the app switcher; .docx/.xlsx/.pptx and legacy Office files render in the browser"
