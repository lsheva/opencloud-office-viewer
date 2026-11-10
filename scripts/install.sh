#!/usr/bin/env sh
# Installs the office-viewer app into an OpenCloud instance.
#
#   sudo sh install.sh office-viewer.zip
#   sudo sh install.sh https://github.com/<owner>/office-viewer/releases/latest/download/office-viewer.zip
#   curl -fsSL <install.sh-url> | sudo sh -s -- <zip-url>
#
# Accepts either a local archive or an http(s) URL, so you can scp the zip to
# the server instead of downloading it there.
#
# Environment:
#   APPS_DIR    default ${OC_DATA_DIR:-/var/lib/opencloud}/web/assets/apps
#   CSP_FILE    optional csp-override.yaml to install (required for rendering)
#   NO_RESTART  set to 1 to skip `systemctl restart opencloud`
set -eu

source_arg=${1:-}
if [ -z "$source_arg" ]; then
  echo "usage: install.sh <zip-url-or-path>" >&2
  exit 2
fi

apps_dir=${APPS_DIR:-${OC_DATA_DIR:-/var/lib/opencloud}/web/assets/apps}
workdir=$(mktemp -d 2>/dev/null || true)
if [ -z "${workdir:-}" ]; then
  # Some environments (busybox, odd TMPDIR) cannot create a temp dir; stay local.
  workdir="./.office-viewer-install.$$"
  mkdir -p "$workdir"
fi
trap 'rm -rf "$workdir"' EXIT

case "$source_arg" in
  http://* | https://*)
    echo "→ downloading $source_arg"
    curl -fsSL "$source_arg" -o "$workdir/app.zip"
    ;;
  *)
    if [ ! -f "$source_arg" ]; then
      echo "no such file: $source_arg" >&2
      exit 1
    fi
    cp "$source_arg" "$workdir/app.zip"
    ;;
esac

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required" >&2
  exit 1
fi
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

mkdir -p "$apps_dir/office-viewer"
cp -a "$bundle/." "$apps_dir/office-viewer/"
echo "→ app installed into $apps_dir/office-viewer"

if [ -n "${CSP_FILE:-}" ]; then
  if [ ! -f "$CSP_FILE" ]; then
    echo "CSP_FILE points at a missing file: $CSP_FILE" >&2
    exit 1
  fi
  cp "$CSP_FILE" /etc/opencloud/csp-override.yaml
  echo "→ CSP override installed to /etc/opencloud/csp-override.yaml"
  echo "  make sure PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION points at it:"
  echo "  Environment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=/etc/opencloud/csp-override.yaml"
fi

if [ "${NO_RESTART:-}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl restart opencloud
  echo "→ opencloud restarted; open the app switcher and pick 'office-viewer'"
else
  echo "→ restart OpenCloud yourself — app manifests are only read at startup"
fi
