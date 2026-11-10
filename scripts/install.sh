#!/usr/bin/env sh
# Installs office-viewer into an OpenCloud instance.
#
#   curl -fsSL https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/scripts/install.sh | sh
#   sh install.sh --detect        # show which apps directory it would use
#
# Nothing needs to be passed: the archive URL, the apps directory and the CSP
# override are all resolved automatically. Privileged steps go through sudo,
# which asks for the password once; without sudo the script prints the
# equivalent commands to run as root.
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

with_csp=${WITH_CSP-1}
csp_source=${CSP_FILE:-https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/csp-override.yaml}
csp_target=${CSP_TARGET:-/etc/opencloud/csp-override.yaml}
dropin=${DROPIN_PATH:-/etc/systemd/system/opencloud.service.d/csp.conf}
sudo_cmd=${SUDO_CMD-sudo}

as_root() {
  if [ "$(id -u)" -eq 0 ] || [ -z "$sudo_cmd" ]; then
    "$@"
  else
    "$sudo_cmd" "$@"
  fi
}

# The main PID's environment is the most reliable source: it reflects the unit,
# its drop-ins and any EnvironmentFile. Falls back to looking at the filesystem,
# then to OpenCloud's documented default.
service_env() {
  command -v systemctl >/dev/null 2>&1 || return 1
  pid=$(systemctl show -p MainPID --value opencloud 2>/dev/null || true)
  [ -n "${pid:-}" ] && [ "$pid" != "0" ] || return 1
  as_root sh -c "tr '\0' '\n' < /proc/$pid/environ" 2>/dev/null || return 1
}

first_match() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

detect_apps_dir() {
  if [ -n "${APPS_DIR:-}" ]; then
    printf '%s' "$APPS_DIR"
    return
  fi
  if [ -n "${WEB_ASSET_APPS_PATH:-}" ]; then
    printf '%s' "$WEB_ASSET_APPS_PATH"
    return
  fi

  env_blob=$(service_env || true)
  if [ -n "${env_blob:-}" ]; then
    explicit=$(first_match "$env_blob" WEB_ASSET_APPS_PATH)
    if [ -n "$explicit" ]; then
      printf '%s' "$explicit"
      return
    fi
    for key in OC_DATA_DIR OC_BASE_DATA_PATH OCIS_BASE_DATA_PATH; do
      data_dir=$(first_match "$env_blob" "$key")
      if [ -n "$data_dir" ]; then
        printf '%s' "$data_dir/web/assets/apps"
        return
      fi
    done
  fi

  # An existing apps directory is good evidence, whatever it is called.
  existing=$(find /var/lib /srv /opt /data /mnt /home -maxdepth 6 -type d \
    -path '*/web/assets/apps' 2>/dev/null | head -1 || true)
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return
  fi

  printf '%s' "${OC_DATA_DIR:-/var/lib/opencloud}/web/assets/apps"
}

apps_dir=$(detect_apps_dir)

if [ "${1:-}" = "--detect" ]; then
  echo "apps dir:  $apps_dir"
  echo "csp file:  $csp_target"
  echo "drop-in:   $dropin"
  exit 0
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required" >&2
  exit 1
fi

manual_steps() {
  cat >&2 <<EOF
This needs root to write $apps_dir and $csp_target. Run as root, or do it by hand:

  tmp=\$(mktemp -d)
  curl -fsSL -o "\$tmp/app.zip" '$source_arg'
  unzip -q "\$tmp/app.zip" -d "\$tmp/x"
  mkdir -p '$apps_dir'
  cp -a "\$tmp/x/office-viewer" '$apps_dir/'

  # CSP override (required, otherwise nothing renders)
  curl -fsSL -o '$csp_target' '$csp_source'
  mkdir -p '$(dirname "$dropin")'
  printf '[Service]\nEnvironment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=%s\n' '$csp_target' > '$dropin'
  systemctl daemon-reload
  systemctl restart opencloud
EOF
}

# Ask for sudo once, up front, instead of mid-install.
if [ "$(id -u)" -ne 0 ] && [ -n "$sudo_cmd" ]; then
  if command -v "$sudo_cmd" >/dev/null 2>&1; then
    "$sudo_cmd" -v || {
      echo "sudo failed — aborting" >&2
      exit 1
    }
  else
    manual_steps
    exit 1
  fi
fi

workdir=$(mktemp -d 2>/dev/null || true)
if [ -z "${workdir:-}" ]; then
  # Some environments (busybox, odd TMPDIR) cannot create a temp dir; stay local.
  workdir="./.office-viewer-install.$$"
  mkdir -p "$workdir"
fi
trap 'rm -rf "$workdir"' EXIT

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

echo "→ apps dir: $apps_dir"
echo "→ fetching $source_arg"
fetch "$source_arg" "$workdir/app.zip"
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

as_root mkdir -p "$apps_dir/office-viewer"
as_root cp -a "$bundle/." "$apps_dir/office-viewer/"
echo "→ app installed into $apps_dir/office-viewer"

if [ "$with_csp" = "1" ]; then
  fetch "$csp_source" "$workdir/csp-override.yaml"
  as_root mkdir -p "$(dirname "$csp_target")" "$(dirname "$dropin")"
  as_root cp "$workdir/csp-override.yaml" "$csp_target"
  printf '[Service]\nEnvironment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=%s\n' "$csp_target" \
    | as_root tee "$dropin" >/dev/null

  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl daemon-reload
  fi
  echo "→ CSP override installed: $csp_target"
  echo "  systemd drop-in:         $dropin"
else
  echo "! CSP override skipped (WITH_CSP=0) — without it the app renders nothing."
fi

if [ "${NO_RESTART:-}" != "1" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    restarted=""
    for unit in opencloud opencloud.service; do
      if as_root systemctl restart "$unit" 2>/dev/null; then
        restarted=$unit
        break
      fi
    done
    if [ -n "$restarted" ]; then
      echo "→ restarted $restarted; the app appears as 'office-viewer' and opens Office files"
    else
      echo "! could not restart via systemd — run: sudo systemctl restart opencloud" >&2
    fi
  else
    echo "→ no systemd here (container?) — restart OpenCloud so it re-reads app manifests"
  fi
else
  echo "→ restart OpenCloud yourself — app manifests are only read at startup"
fi
