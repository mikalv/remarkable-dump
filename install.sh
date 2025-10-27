#!/bin/sh
# install.sh - one-shot rm-support helper for reMarkable
# Usage:
#   wget https://raw.githubusercontent.com/mikalv/remarkable-dump/main/install.sh -O- | sh

set -eu

RAW_BASE=${RAW_BASE:-https://raw.githubusercontent.com/mikalv/remarkable-dump/main}
BIN_NAME=rm-support-http
SCRIPT_NAME=rm-support.sh
KEEP_INSTALL=${KEEP_INSTALL:-0}
server_pid=""
stop_server_on_exit=1
cleanup_files_on_exit=1
install_dir=""
dir_created=0
installed_script=""
installed_bin=""

tmpdir="$(mktemp -d /tmp/rm-support-install.XXXXXX)"

cleanup() {
  if [ "$stop_server_on_exit" = "1" ] && [ -n "$server_pid" ]; then
    if kill -0 "$server_pid" 2>/dev/null; then
      kill "$server_pid" 2>/dev/null || true
      wait "$server_pid" 2>/dev/null || true
    fi
  fi
  if [ "$cleanup_files_on_exit" = "1" ] && [ "${KEEP_INSTALL}" = "0" ]; then
    if [ -n "$installed_script" ]; then
      rm -f "$installed_script"
    fi
    if [ -n "$installed_bin" ]; then
      rm -f "$installed_bin"
    fi
    if [ "$dir_created" = "1" ] && [ -n "$install_dir" ]; then
      rmdir "$install_dir" 2>/dev/null || true
    fi
  fi
  rm -rf "$tmpdir"
}
trap cleanup INT TERM EXIT

fetch() {
  url="$1"
  dest="$2"
  echo "-> downloading $(basename "$url")"
  if ! wget -q -O "$dest" "$url"; then
    echo "!! failed to download $url" >&2
    exit 1
  fi
}

if [ -n "${INSTALL_DIR:-}" ]; then
  install_dir="$INSTALL_DIR"
  if [ -d "$install_dir" ]; then
    dir_created=0
  else
    mkdir -p "$install_dir"
    dir_created=1
  fi
else
  install_dir="$(mktemp -d /home/root/rm-support.XXXXXX 2>/dev/null || mktemp -d /tmp/rm-support.XXXXXX)"
  dir_created=1
fi

echo "Working directory: ${install_dir}"

fetch "${RAW_BASE}/${SCRIPT_NAME}" "${install_dir}/${SCRIPT_NAME}"
fetch "${RAW_BASE}/bin/${BIN_NAME}" "${install_dir}/${BIN_NAME}"

installed_script="${install_dir}/${SCRIPT_NAME}"
installed_bin="${install_dir}/${BIN_NAME}"

chmod 755 "${installed_script}" "${installed_bin}"

echo ""
echo "Running support bundle collector..."
if "${installed_script}" >"${tmpdir}/support.log" 2>&1; then
  cat "${tmpdir}/support.log"
else
  cat "${tmpdir}/support.log"
  echo "!! support script failed" >&2
  exit 1
fi

bundle_path="$(awk -F': ' '/Support bundle created:/ {print $2}' "${tmpdir}/support.log" | tail -n1)"
bundle_path="$(printf '%s' "${bundle_path}" | sed 's/[[:space:]]*$//')"

if [ -z "${bundle_path}" ] || [ ! -f "${bundle_path}" ]; then
  echo "!! could not locate generated bundle" >&2
  exit 1
fi

echo ""
echo "Starting temporary HTTP server..."
rm_http_bind=${RM_HTTP_BIND:-0.0.0.0:8080}
rm_http_dir=${RM_HTTP_DIR:-$(dirname "${bundle_path}")}

RM_HTTP_BIND="${rm_http_bind}" RM_HTTP_DIR="${rm_http_dir}" "${installed_bin}" >"${tmpdir}/http.log" 2>&1 &
server_pid=$!
sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
  echo "!! failed to start HTTP server" >&2
  cat "${tmpdir}/http.log" >&2
  exit 1
fi

cat "${tmpdir}/http.log"

find_ip() {
  for iface in ${RM_HTTP_IFACES:-usb0 wlan0 eth0}; do
    if ip -4 addr show "$iface" >/dev/null 2>&1; then
      addr="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
      if [ -n "$addr" ]; then
        echo "$addr"
        return
      fi
    fi
  done
  ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2}' | cut -d/ -f1 | head -n1
}

device_ip="$(find_ip)"
bundle_name="$(basename "${bundle_path}")"
bundle_dir="$(dirname "${bundle_path}")"
port="${rm_http_bind##*:}"

echo ""
echo "[OK] Support bundle ready: ${bundle_path}"
echo "[INFO] Stored in: ${bundle_dir}"

suggest_url() {
  if [ -n "${device_ip}" ]; then
    printf '%s' "http://${device_ip}:${port}"
  elif [ "${rm_http_bind}" = "0.0.0.0:${port}" ]; then
    printf '%s' "http://<device-ip>:${port}"
  else
    printf '%s' "http://${rm_http_bind}"
  fi
}

base_url="$(suggest_url)"

echo ""
echo "===================="
echo "Download this file:"
echo "  ${base_url}/download/${bundle_name}"
echo ""
echo "Need the newest bundle automatically?"
echo "  ${base_url}/download/latest"
echo "===================="

echo ""
echo "Press Enter after the download completes to stop the server and clean up."
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
  read _ </dev/tty || true
else
  echo "[INFO] No interactive terminal detected."
  echo "[INFO] The HTTP server will keep running in the background."
  echo "[INFO] Stop it later with:"
  echo "       kill ${server_pid}"
  echo "[INFO] Cleanup skipped so the download stays available."
  stop_server_on_exit=0
  cleanup_files_on_exit=0
  KEEP_INSTALL=1
fi

if [ "$stop_server_on_exit" = "1" ] && [ -n "$server_pid" ]; then
  if kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
fi

if [ "$cleanup_files_on_exit" = "1" ] && [ "${KEEP_INSTALL}" = "0" ]; then
  if [ -n "$installed_script" ]; then
    rm -f "$installed_script"
  fi
  if [ -n "$installed_bin" ]; then
    rm -f "$installed_bin"
  fi
  if [ "${dir_created}" = "1" ]; then
    rmdir "${install_dir}" 2>/dev/null || true
  fi
  echo "[INFO] Removed temporary files."
else
  echo "[INFO] Keeping files in ${install_dir} (KEEP_INSTALL=${KEEP_INSTALL})."
fi

echo ""
echo "Done."
