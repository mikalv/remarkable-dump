#!/bin/sh
# rm-support.sh — reMarkable debug-dump for support
# Works with BusyBox/ash. No pipefail, no GNU-only flags.

set -eu

# ---- Config ---------------------------------------------------------------
OUTDIR_BASE="/home/root"
LABEL="${LABEL:-rm-debug}"
NOW="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d /tmp/${LABEL}.XXXXXX)"
OUTDIR="${WORKDIR}/collect"
ARCHIVE="${OUTDIR_BASE}/${LABEL}-${NOW}.tgz"

# Minimal timeout helper (BusyBox timeout may not exist)
run() {
  CMD="$1"; shift || true
  echo "\$ ${CMD} $*" >"$OUTDIR/cmd/${CMD##*/}.cmd"
  # run command, capture stdout+stderr to file
  ( "$CMD" "$@" ) >"$OUTDIR/cmd/${CMD##*/}.out" 2>"$OUTDIR/cmd/${CMD##*/}.err" || true
}

mkdir -p "$OUTDIR"/{cmd,logs,sys,config,network,units,packages}

# ---- System snapshot -------------------------------------------------------
# Kernel & OS
uname -a > "$OUTDIR/sys/uname.txt" 2>&1 || true
[ -f /etc/os-release ] && cp /etc/os-release "$OUTDIR/sys/os-release.txt" || true
date -u > "$OUTDIR/sys/date_utc.txt" 2>&1 || true

# Storage & memory
df -h    > "$OUTDIR/sys/df.txt" 2>&1 || true
mount    > "$OUTDIR/sys/mount.txt" 2>&1 || true
free -m  > "$OUTDIR/sys/free.txt" 2>&1 || true
lsblk    > "$OUTDIR/sys/lsblk.txt" 2>&1 || true || true
cat /proc/cmdline > "$OUTDIR/sys/proc_cmdline.txt" 2>&1 || true

# Modules, USB, devices (best-effort)
lsmod       > "$OUTDIR/sys/lsmod.txt" 2>&1 || true
lsusb       > "$OUTDIR/sys/lsusb.txt" 2>&1 || true
dmesg       > "$OUTDIR/logs/dmesg.txt" 2>&1 || true

# reMarkable bits that exist on the image
[ -x /usr/bin/get-battery-info.sh ] && /usr/bin/get-battery-info.sh > "$OUTDIR/sys/battery.txt" 2>&1 || true
[ -x /usr/bin/memfault-device-info ] && /usr/bin/memfault-device-info > "$OUTDIR/sys/memfault-device-info.txt" 2>&1 || true
[ -x /usr/bin/memfaultctl ] && memfaultctl status > "$OUTDIR/sys/memfaultctl-status.txt" 2>&1 || true

# ---- Systemd snapshot ------------------------------------------------------
# (BusyBox systemd build supports these verbs)
run systemctl list-units --all
run systemctl list-unit-files
run systemctl status
run systemctl list-timers
run systemctl list-sockets
run systemctl show

# Services commonly relevant on rm
for SVC in xochitl rm-sync mdm-agent memfaultd swupdate wpa_supplicant dropbear; do
  systemctl status "$SVC" > "$OUTDIR/units/${SVC}.status.txt" 2>&1 || true
  journalctl -u "$SVC" -n 2000 -o short-iso > "$OUTDIR/logs/${SVC}.journal.txt" 2>&1 || true
done

# Full journal (last ~10k lines to keep size sane)
journalctl -n 10000 -o short-iso > "$OUTDIR/logs/journal_tail.txt" 2>&1 || true

# ---- Network snapshot ------------------------------------------------------
ip addr show   > "$OUTDIR/network/ip_addr.txt" 2>&1 || true
ip route show  > "$OUTDIR/network/ip_route.txt" 2>&1 || true
ifconfig -a    > "$OUTDIR/network/ifconfig.txt" 2>&1 || true
wpa_cli -i wlan0 status > "$OUTDIR/network/wpa_status.txt" 2>&1 || true
iw dev         > "$OUTDIR/network/iw_dev.txt" 2>&1 || true
iw wlan0 link  > "$OUTDIR/network/iw_link.txt" 2>&1 || true
resolvectl status > "$OUTDIR/network/resolvectl.txt" 2>&1 || true
cat /etc/hosts > "$OUTDIR/network/hosts.txt" 2>&1 || true

# Wi-Fi configs with redaction
redact_psk() {
  # Redact common psk formats (wpa_supplicant)
  sed -E \
    -e 's/(psk=)([^"]+)/\1<redacted>/g' \
    -e 's/(psk=")[^"]+(")/\1<redacted>\2/g' \
    -e 's/(wep_key[0-9]*=).*/\1<redacted>/g'
}

if [ -f /home/root/.config/remarkable/wifi_networks.conf ]; then
  mkdir -p "$OUTDIR/config"
  redact_psk < /home/root/.config/remarkable/wifi_networks.conf \
    > "$OUTDIR/config/wifi_networks.conf.redacted"
fi

[ -f /etc/wpa_supplicant.conf ] && redact_psk < /etc/wpa_supplicant.conf > "$OUTDIR/config/wpa_supplicant.conf.redacted" || true

# ---- reMarkable app & config (no user documents!) -------------------------
# Avoid copying documents; only metadata/configs
for f in \
  /etc/remarkable/* \
  /home/root/.config/remarkable/* \
  /var/log/* \
  ; do
  [ -e "$f" ] || continue
  case "$f" in
    *wifi_networks.conf|*wpa_supplicant.conf) : ;; # already handled w/ redaction
    *)
      # copy as text if small, else tar path later
      if [ -f "$f" ] && [ "$(busybox stat -c%s "$f" 2>/dev/null || echo 0)" -lt 1048576 ]; then
        # small-ish file
        REL="${f#/}"
        DEST="$OUTDIR/config/${REL}"
        mkdir -p "$(dirname "$DEST")"
        cp -a "$f" "$DEST" 2>/dev/null || true
      fi
    ;;
  esac
done

# Process list (BusyBox ps minimal)
ps > "$OUTDIR/sys/ps.txt" 2>&1 || true

# Versions of key binaries (best-effort)
for bin in /usr/bin/xochitl /usr/bin/mdm-agent /usr/bin/rm-sync /usr/bin/swupdate /usr/bin/memfaultd; do
  if [ -x "$bin" ]; then
    echo "$bin:" > "$OUTDIR/packages/$(basename "$bin").txt"
    strings "$bin" | grep -E '(^v[0-9]+\.[0-9]+|version|git|commit|build)' >> "$OUTDIR/packages/$(basename "$bin").txt" 2>/dev/null || true
  fi
done

# Kernel & boot identifiers
[ -f /proc/version ] && cat /proc/version > "$OUTDIR/sys/proc_version.txt" 2>&1 || true

# ---- Package everything ----------------------------------------------------
# Also include a small manifest
{
  echo "label=${LABEL}"
  echo "created_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "hostname=$(hostname 2>/dev/null || echo unknown)"
  echo "kernel=$(uname -r 2>/dev/null || echo unknown)"
} > "$OUTDIR/manifest.txt"

# Create archive
# Use busybox tar/gzip (present on device)
(
  cd "$WORKDIR"
  tar -czf "$ARCHIVE" "$(basename "$OUTDIR")"
)

# Cleanup working dir (keep the archive)
rm -rf "$WORKDIR" || true

echo ""
echo "✅ Support bundle created: $ARCHIVE"
echo "Copy it off the device with:"
echo "  scp root@\$(ip -4 addr show usb0 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 || echo 10.11.99.1):$ARCHIVE ."
echo ""
