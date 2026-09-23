#!/usr/bin/env bash
# variants/bastion-edge/tests/smoke.sh — boot the built bastion-edge image in
# QEMU/KVM, SSH in as edge-operator, verify firstboot produced an edge-id,
# bastion-theatre-manager is active, and nothing dev-tooling leaked in.
#
# Usage: bash variants/bastion-edge/tests/smoke.sh [output-dir]
#
# Requirements:
#   - qemu-system-x86_64 with KVM (/dev/kvm accessible)
#   - zstd (to decompress .raw.zst image)
#   - ssh + keys/authorized_key (same key baked into blueprint via Makefile)
#   - a built image from: make VARIANT=bastion-edge image
#
# Firstboot on edge is fast (no brew, no npm) — a 120 s cap is generous.
# Tune TIMEOUT_FIRSTBOOT if you're running under heavy IO contention.
set -euo pipefail

OUTDIR="${1:-output}"
SSH_KEY="${SSH_KEY:-keys/authorized_key}"
SSH_PORT="${SSH_PORT:-2232}"   # distinct from devbox (2222) so both can run concurrently
SSH_USER="${SSH_USER:-edge-operator}"
TIMEOUT_SSH="${TIMEOUT_SSH:-120}"
TIMEOUT_FIRSTBOOT="${TIMEOUT_FIRSTBOOT:-300}"
TIMEOUT_SECONDBOOT="${TIMEOUT_SECONDBOOT:-180}"
FAIL_LOG="${FAIL_LOG:-$OUTDIR/smoke-fail.log}"
VERBOSE="${VERBOSE:-0}"
SKIP_REBOOT="${SKIP_REBOOT:-0}"
SERIAL_TAIL="${SERIAL_TAIL:-1}"
SSH_UP=0
FINISHED=0
TAIL_PID=""
START_EPOCH=$(date +%s)
BOOT_SECS=""
FIRSTBOOT_SECS=""
SECONDBOOT_SECS=""

log()    { echo "[smoke] $(date -Iseconds) $*"; }
sub()    { printf '  %s\n' "$*"; }
row()    { printf '  %-16s %s\n' "$1" "$2"; }
status() { printf '  %s %s\n' "$1" "$2"; }

dump_journal() {
    [[ "$FINISHED" == "1" ]] && return
    [[ "$SSH_UP" == "1" ]] || { log "SSH never came up — no journal to capture"; return; }
    log "Capturing firstboot journal → $FAIL_LOG"
    mkdir -p "$(dirname "$FAIL_LOG")"
    {
        echo "=== bastion-edge-firstboot ==="
        ssh "${SSH_OPTS[@]}" "journalctl -u bastion-edge-firstboot --no-pager" 2>&1 || true
        echo
        echo "=== bastion-theatre-manager ==="
        ssh "${SSH_OPTS[@]}" "journalctl -u bastion-theatre-manager --no-pager" 2>&1 || true
    } > "$FAIL_LOG"
}

dump_serial() {
    [[ -s "${SERIAL_LOG:-}" ]] || { log "No serial output captured"; return; }
    log "Last 80 lines of serial console ($SERIAL_LOG):"
    tail -n 80 "$SERIAL_LOG" | sed 's/^/[serial] /'
}

dump_qemu() {
    [[ -s "${QEMU_LOG:-}" ]] || return
    log "QEMU stderr ($QEMU_LOG):"
    sed 's/^/[qemu] /' "$QEMU_LOG"
}

die() {
    log "ERROR: $*"
    echo "[smoke] ERROR: $*" >&2
    dump_qemu
    dump_serial
    dump_journal
    exit 1
}

# ── Locate image ─────────────────────────────────────────────────────────────
# SMOKE_FORMAT selects which output artifact to boot:
#   raw   → decompress *.raw.zst (field-deploy dd target; default)
#   qcow2 → copy *.qcow2 (ADCON runtime target; proves bastion-qemu consumption)
SMOKE_FORMAT="${SMOKE_FORMAT:-raw}"
case "$SMOKE_FORMAT" in
    raw)
        IMAGE=$(find "$OUTDIR" -name '*.raw.zst' | sort | tail -1)
        [[ -n "$IMAGE" ]] || die "no .raw.zst image in $OUTDIR — run: make VARIANT=bastion-edge image"
        TMPIMAGE=$(mktemp /tmp/smoke-edge-XXXXXX.raw)
        DRIVE_FMT=raw
        ;;
    qcow2)
        IMAGE=$(find "$OUTDIR" -maxdepth 1 -name '*.qcow2' | sort | tail -1)
        [[ -n "$IMAGE" ]] || die "no .qcow2 in $OUTDIR — run: make VARIANT=bastion-edge image"
        TMPIMAGE=$(mktemp /tmp/smoke-edge-XXXXXX.qcow2)
        DRIVE_FMT=qcow2
        ;;
    *)
        die "unsupported SMOKE_FORMAT='$SMOKE_FORMAT' (want: raw|qcow2)"
        ;;
esac
log "Image: $IMAGE ($SMOKE_FORMAT)"

QEMU_PID=""
cleanup() {
    dump_journal 2>/dev/null || true
    [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null || true
    rm -f "$TMPIMAGE" "${TMPVARS:-}"
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$SMOKE_FORMAT" == "raw" ]]; then
    log "Decompressing $(basename "$IMAGE") → $TMPIMAGE"
    zstd -df --quiet "$IMAGE" -o "$TMPIMAGE"
else
    log "Copying $(basename "$IMAGE") → $TMPIMAGE (reflink when supported)"
    cp --reflink=auto "$IMAGE" "$TMPIMAGE"
fi

OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/ovmf/OVMF_VARS.fd}"
[[ -r "$OVMF_CODE" ]] || die "OVMF_CODE not readable: $OVMF_CODE (install edk2-ovmf)"
[[ -r "$OVMF_VARS_SRC" ]] || die "OVMF_VARS not readable: $OVMF_VARS_SRC"
TMPVARS=$(mktemp /tmp/smoke-edge-vars-XXXXXX.fd)
cp "$OVMF_VARS_SRC" "$TMPVARS"

SERIAL_LOG="${SERIAL_LOG:-$OUTDIR/smoke-serial.log}"
QEMU_LOG="${QEMU_LOG:-$OUTDIR/smoke-qemu.log}"
mkdir -p "$(dirname "$SERIAL_LOG")"
: > "$SERIAL_LOG"
: > "$QEMU_LOG"
log "Serial console → $SERIAL_LOG"
log "QEMU stderr    → $QEMU_LOG"

log "Booting VM (SSH forwarded to localhost:$SSH_PORT)"
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host \
    -m 2048 \
    -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$TMPVARS" \
    -drive "file=$TMPIMAGE,format=$DRIVE_FMT,if=virtio" \
    -net nic,model=virtio \
    -net "user,hostfwd=tcp::${SSH_PORT}-:22" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -monitor none \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log "QEMU PID $QEMU_PID"

sleep 2
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null || true
    dump_qemu
    dump_serial
    die "QEMU exited before VM came up"
fi

if [[ "$SERIAL_TAIL" == "1" ]]; then
    tail -F "$SERIAL_LOG" 2>/dev/null | sed -u 's/^/[vm] /' &
    TAIL_PID=$!
fi

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -i "$SSH_KEY"
    -p "$SSH_PORT"
    "${SSH_USER}@localhost"
)
AVC_DENIALS_SH="$(dirname "$0")/../../../scripts/avc-denials.sh"

# ── Wait for SSH ─────────────────────────────────────────────────────────────
log "Waiting for SSH (up to ${TIMEOUT_SSH}s)"
deadline=$(( $(date +%s) + TIMEOUT_SSH ))
until ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
    (( $(date +%s) < deadline )) || die "SSH not available within ${TIMEOUT_SSH}s"
    sleep 3
done
SSH_UP=1
BOOT_SECS=$(( $(date +%s) - START_EPOCH ))
log "SSH up (${BOOT_SECS}s from start)"

# ── Wait for FEDBUILD_READY on serial ────────────────────────────────────────
log "Waiting for FEDBUILD_READY on serial (up to ${TIMEOUT_FIRSTBOOT}s)"
fb_start=$(date +%s)
set +e
timeout "$TIMEOUT_FIRSTBOOT" awk '
    /^FEDBUILD_READY/  { print; exit 0 }
    /^FEDBUILD_FAILED/ { print; exit 1 }
' < <(tail -F -n +1 "$SERIAL_LOG" 2>/dev/null) >/dev/null
fb_rc=$?
set -e
case "$fb_rc" in
    0)   : ;;
    1)   die "FEDBUILD_FAILED marker seen on serial — see [vm] stream above" ;;
    124) die "FEDBUILD_READY not seen within ${TIMEOUT_FIRSTBOOT}s" ;;
    *)   die "serial wait returned unexpected rc=$fb_rc" ;;
esac
FIRSTBOOT_SECS=$(( $(date +%s) - fb_start ))
log "FEDBUILD_READY seen (${FIRSTBOOT_SECS}s)"
export FIRSTBOOT_SECS

# ── Core assertions ──────────────────────────────────────────────────────────
FAIL=""

log "TheatreManager"
# `systemctl show -p ActiveState --value` always exits 0 and prints a single
# word (active|inactive|failed|…), unlike `is-active` which exits 3 on
# inactive — an `|| echo fallback` there would append a second line and
# break downstream equality checks.
tm_state=$(ssh "${SSH_OPTS[@]}" 'systemctl show -p ActiveState --value bastion-theatre-manager 2>/dev/null')
row "is-active" "$tm_state"
[[ "$tm_state" == "active" ]] || { status "✗" "bastion-theatre-manager not active (got: $tm_state)"; FAIL=1; }

log "Firstboot sentinels"
done_present=$(ssh "${SSH_OPTS[@]}" '[[ -f /var/lib/bastion-edge/done ]] && echo yes || echo no')
failed_present=$(ssh "${SSH_OPTS[@]}" '[[ -f /var/lib/bastion-edge/failed ]] && echo yes || echo no')
edge_id=$(ssh "${SSH_OPTS[@]}" 'cat /var/lib/bastion-edge/edge-id 2>/dev/null || echo ""')
fb_state=$(ssh "${SSH_OPTS[@]}" 'systemctl show -p ActiveState --value bastion-edge-firstboot 2>/dev/null')
row "done"     "$done_present"
row "failed"   "$failed_present"
row "edge-id"  "${edge_id:-<empty>}"
row "service"  "$fb_state"
[[ "$done_present"   == "yes" ]] || { status "✗" "done sentinel missing"; FAIL=1; }
[[ "$failed_present" == "no"  ]] || { status "✗" "failed sentinel present — firstboot errored"; FAIL=1; }
[[ -n "$edge_id"              ]] || { status "✗" "edge-id empty or missing"; FAIL=1; }
case "$fb_state" in
    active|inactive) ;;   # oneshot: active (RemainAfterExit=yes) or inactive (after reboot)
    *) status "✗" "firstboot unit in unexpected state: $fb_state"; FAIL=1 ;;
esac

# ── Leakage checks — edge must NOT have dev tooling ──────────────────────────
log "No-dev-tooling"
has_brew=$(ssh "${SSH_OPTS[@]}" '[[ -d /home/linuxbrew ]] && echo yes || echo no')
# shellcheck disable=SC2029  # intentional client-side expansion of $SSH_USER into the remote test
has_claude=$(ssh "${SSH_OPTS[@]}" "[[ -d /home/${SSH_USER}/.claude ]] && echo yes || echo no")
has_nodejs=$(ssh "${SSH_OPTS[@]}" 'command -v node >/dev/null 2>&1 && echo yes || echo no')
row "linuxbrew"  "$has_brew"
row "claude dir" "$has_claude"
row "nodejs"     "$has_nodejs"   # should be yes — bastion-theatre-manager requires it
[[ "$has_brew"   == "no"  ]] || { status "✗" "/home/linuxbrew present — dev tooling leaked"; FAIL=1; }
[[ "$has_claude" == "no"  ]] || { status "✗" "agent config present — dev tooling leaked"; FAIL=1; }
[[ "$has_nodejs" == "yes" ]] || { status "✗" "node missing — TheatreManager cannot start"; FAIL=1; }

# ── SELinux ──────────────────────────────────────────────────────────────────
log "SELinux"
selinux_mode=$(ssh "${SSH_OPTS[@]}" 'getenforce 2>/dev/null || echo unknown')
avc_count=error
avc_list=$(ssh "${SSH_OPTS[@]}" bash -s <"$AVC_DENIALS_SH") && avc_count=$(grep -c . <<<"$avc_list" || true)
row "enforce"     "$selinux_mode"
row "AVC denials" "$avc_count"
[[ "$selinux_mode" == "Enforcing" ]] || { status "✗" "SELinux not enforcing (got: $selinux_mode)"; FAIL=1; }
[[ "$avc_count" == 0 ]] || {
    status "✗" "SELinux AVC denials since boot: $avc_count"
    head -5 <<<"$avc_list" | sed 's/^/  /'
    FAIL=1
}

# ── Release file ─────────────────────────────────────────────────────────────
log "Release file"
if ssh "${SSH_OPTS[@]}" 'test -f /etc/bastion-edge-release' 2>/dev/null; then
    release=$(ssh "${SSH_OPTS[@]}" 'cat /etc/bastion-edge-release' 2>/dev/null \
        | awk -F= '/^VERSION=/{v=$2}/^GIT_COMMIT=/{g=$2}END{printf "v%s @ %s", v, substr(g,1,10)}')
    row "release" "$release"
else
    status "✗" "/etc/bastion-edge-release missing"
    FAIL=1
fi

[[ -z "$FAIL" ]] || die "smoke assertions failed"

# ── Success journal dump ─────────────────────────────────────────────────────
SUCCESS_LOG="${SUCCESS_LOG:-$OUTDIR/smoke-firstboot.log}"
log "Capturing firstboot journal → $SUCCESS_LOG"
{
    echo "=== bastion-edge-firstboot ==="
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-edge-firstboot --no-pager -o cat" 2>&1 || true
    echo
    echo "=== bastion-theatre-manager ==="
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-theatre-manager --no-pager -o cat" 2>&1 || true
} > "$SUCCESS_LOG"

# ── Reboot-persistence ───────────────────────────────────────────────────────
if [[ "$SKIP_REBOOT" == "1" ]]; then
    log "Reboot phase skipped (SKIP_REBOOT=1)"
else
    log "Reboot-persistence"
    pre_mtime=$(ssh "${SSH_OPTS[@]}" 'stat -c%Y /var/lib/bastion-edge/done 2>/dev/null || echo 0')
    row "done mtime" "$pre_mtime (pre-reboot)"
    ssh "${SSH_OPTS[@]}" 'sudo systemctl reboot' 2>/dev/null || true
    reboot_start=$(date +%s)
    sleep 3
    log "waiting for SSH back (up to ${TIMEOUT_SECONDBOOT}s)"
    deadline=$(( reboot_start + TIMEOUT_SECONDBOOT ))
    until ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
        (( $(date +%s) < deadline )) || die "VM did not come back within ${TIMEOUT_SECONDBOOT}s"
        sleep 3
    done
    ssh "${SSH_OPTS[@]}" 'timeout 30 systemctl is-system-running --wait' \
        >/dev/null 2>&1 || true
    SECONDBOOT_SECS=$(( $(date +%s) - reboot_start ))
    export SECONDBOOT_SECS
    row "secondboot" "${SECONDBOOT_SECS}s"

    post_mtime=$(ssh "${SSH_OPTS[@]}" 'stat -c%Y /var/lib/bastion-edge/done 2>/dev/null || echo 0')
    post_failed=$(ssh "${SSH_OPTS[@]}" '[[ -f /var/lib/bastion-edge/failed ]] && echo yes || echo no')
    post_tm=$(ssh "${SSH_OPTS[@]}" 'systemctl show -p ActiveState --value bastion-theatre-manager 2>/dev/null')
    post_fb=$(ssh "${SSH_OPTS[@]}" 'systemctl show -p ActiveState --value bastion-edge-firstboot 2>/dev/null')
    post_avc=error
    post_avc_list=$(ssh "${SSH_OPTS[@]}" bash -s <"$AVC_DENIALS_SH") && post_avc=$(grep -c . <<<"$post_avc_list" || true)
    row "done mtime"   "$post_mtime (post-reboot)"
    row "failed"       "$post_failed"
    row "TM service"   "$post_tm"
    row "FB service"   "$post_fb"
    row "AVC denials"  "$post_avc"
    FAIL=""
    [[ "$pre_mtime" != "0" && "$post_mtime" == "$pre_mtime" ]] || \
        { status "✗" "done sentinel mtime changed (pre=$pre_mtime post=$post_mtime) — firstboot re-ran"; FAIL=1; }
    [[ "$post_failed" == "no"     ]] || { status "✗" "failed sentinel appeared after reboot"; FAIL=1; }
    [[ "$post_tm"     == "active" ]] || { status "✗" "bastion-theatre-manager not active post-reboot: $post_tm"; FAIL=1; }
    case "$post_fb" in
        inactive|active) ;;
        *) status "✗" "firstboot service in unexpected state: $post_fb"; FAIL=1 ;;
    esac
    [[ "$post_avc" == 0 ]] || { status "✗" "SELinux AVC denials after reboot: $post_avc"; FAIL=1; }
    [[ -z "$FAIL" ]] || die "reboot-persistence assertions failed"
fi

FINISHED=1
ssh "${SSH_OPTS[@]}" "sudo poweroff" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

TOTAL_SECS=$(( $(date +%s) - START_EPOCH ))
IMG_SIZE=$(stat -c%s "$IMAGE" 2>/dev/null | awk '{printf "%.1fG", $1/1024/1024/1024}')
log "PASSED  image=$(basename "$IMAGE")  size=${IMG_SIZE:-?}  boot=${BOOT_SECS:-?}s  firstboot=${FIRSTBOOT_SECS:-?}s  secondboot=${SECONDBOOT_SECS:-skip}s  total=${TOTAL_SECS}s"
