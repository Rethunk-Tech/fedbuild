#!/usr/bin/env bash
# tests/smoke.sh — boot the built VM image in QEMU/KVM, SSH in, verify firstboot.
#
# Usage: bash tests/smoke.sh [output-dir]
#
# Requirements:
#   - qemu-system-x86_64 with KVM (/dev/kvm accessible)
#   - zstd (to decompress .raw.zst image)
#   - ssh + keys/authorized_key
#   - A built image from: make image
#
# The firstboot service can take up to 20 min (Homebrew installs).
# Tune TIMEOUT_FIRSTBOOT if needed.
set -euo pipefail

OUTDIR="${1:-output}"
SSH_KEY="${SSH_KEY:-keys/authorized_key}"
SSH_PORT="${SSH_PORT:-2222}"
TIMEOUT_SSH="${TIMEOUT_SSH:-120}"
TIMEOUT_FIRSTBOOT="${TIMEOUT_FIRSTBOOT:-1200}"
FAIL_LOG="${FAIL_LOG:-$OUTDIR/smoke-fail.log}"
VERBOSE="${VERBOSE:-0}"
SKIP_REBOOT="${SKIP_REBOOT:-0}"
TIMEOUT_SECONDBOOT="${TIMEOUT_SECONDBOOT:-180}"
SERIAL_TAIL="${SERIAL_TAIL:-1}"   # 1 = stream VM serial live to stdout, 0 = silent (log only)
SSH_UP=0
FINISHED=0
TAIL_PID=""
START_EPOCH=$(date +%s)
BOOT_SECS=""        # populated when SSH comes up
FIRSTBOOT_SECS=""   # populated from Timing summary "total" row
SECONDBOOT_SECS=""  # populated after reboot-persistence phase
TOOLS_OK=0
TOOLS_TOTAL=0

log() { echo "[smoke] $(date -Iseconds) $*"; }
# sub: indented sub-line without prefix/timestamp — reduces noise under section headers.
sub() { printf '  %s\n' "$*"; }
# row: aligned "label  value" under a section header.
row() { printf '  %-12s %s\n' "$1" "$2"; }
# status: "✓ label" or "✗ label" — glyph + item for pass/fail checks.
status() { printf '  %s %s\n' "$1" "$2"; }

# dump_journal: grab firstboot journal to $FAIL_LOG (best-effort; SSH may be down)
# Always called on exit (success or failure) via EXIT trap below — an empty
# smoke-fail.log that isn't written means SSH never came up, not that we skipped.
# FINISHED=1 means the success path already captured $SUCCESS_LOG and powered
# off the VM; the trap's capture would only produce "connection refused".
dump_journal() {
    [[ "$FINISHED" == "1" ]] && return
    [[ "$SSH_UP" == "1" ]] || { log "SSH never came up — no journal to capture"; return; }
    log "Capturing firstboot journal → $FAIL_LOG"
    mkdir -p "$(dirname "$FAIL_LOG")"
    ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager" \
        > "$FAIL_LOG" 2>&1 || log "  (journal capture failed)"
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
    # Route the error to both stdout (so wrappers capturing only stdout see it)
    # and stderr (so TTY users see red exit context). Dumps run on stdout via
    # log/sed prefixes; EXIT trap's cleanup will also call dump_journal.
    log "ERROR: $*"
    echo "[smoke] ERROR: $*" >&2
    dump_qemu
    dump_serial
    dump_journal
    exit 1
}

# ── Locate image ──────────────────────────────────────────────────────────────
# SMOKE_FORMAT selects which output artifact to boot:
#   raw   → decompress *.raw.zst (field-deploy dd target; default)
#   qcow2 → copy *.qcow2 (ADCON runtime target; proves bastion-qemu consumption)
SMOKE_FORMAT="${SMOKE_FORMAT:-raw}"
case "$SMOKE_FORMAT" in
    raw)
        IMAGE=$(find "$OUTDIR" -name '*.raw.zst' | sort | tail -1)
        [[ -n "$IMAGE" ]] || die "no .raw.zst image in $OUTDIR — run: make image"
        TMPIMAGE=$(mktemp /tmp/smoke-XXXXXX.raw)
        DRIVE_FMT=raw
        ;;
    qcow2)
        IMAGE=$(find "$OUTDIR" -maxdepth 1 -name '*.qcow2' | sort | tail -1)
        [[ -n "$IMAGE" ]] || die "no .qcow2 in $OUTDIR — run: make image"
        TMPIMAGE=$(mktemp /tmp/smoke-XXXXXX.qcow2)
        DRIVE_FMT=qcow2
        ;;
    *)
        die "unsupported SMOKE_FORMAT='$SMOKE_FORMAT' (want: raw|qcow2)"
        ;;
esac
log "Image: $IMAGE ($SMOKE_FORMAT)"

QEMU_PID=""
cleanup() {
    # Always grab the firstboot journal if SSH ever came up — avoids losing
    # diagnostics when the script exits via die() vs normal path.
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

# OVMF (UEFI) firmware — minimal-raw-zst boots via UEFI only.
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/edk2/ovmf/OVMF_VARS.fd}"
[[ -r "$OVMF_CODE" ]] || die "OVMF_CODE not readable: $OVMF_CODE (install edk2-ovmf)"
[[ -r "$OVMF_VARS_SRC" ]] || die "OVMF_VARS not readable: $OVMF_VARS_SRC"
TMPVARS=$(mktemp /tmp/smoke-vars-XXXXXX.fd)
cp "$OVMF_VARS_SRC" "$TMPVARS"

SERIAL_LOG="${SERIAL_LOG:-$OUTDIR/smoke-serial.log}"
QEMU_LOG="${QEMU_LOG:-$OUTDIR/smoke-qemu.log}"
mkdir -p "$(dirname "$SERIAL_LOG")"
: > "$SERIAL_LOG"
: > "$QEMU_LOG"
log "Serial console → $SERIAL_LOG"
log "QEMU stderr    → $QEMU_LOG"

# ── Boot VM ───────────────────────────────────────────────────────────────────
log "Booting VM (SSH forwarded to localhost:$SSH_PORT)"
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host \
    -m 4096 \
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

# Give QEMU a moment to exec; if it died immediately, surface the error now.
sleep 2
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" 2>/dev/null || true
    dump_qemu
    dump_serial
    die "QEMU exited before VM came up"
fi

# Live-stream VM serial to stdout so kernel boot, systemd units, and firstboot
# progress (journal+console) are visible as they happen — no more blind waits.
# -F follows the name across truncation; prefix distinguishes VM lines from
# smoke's own log output. QEMU opens $SERIAL_LOG in append mode, so the file
# already exists (pre-truncated above); tail attaches cleanly.
if [[ "$SERIAL_TAIL" == "1" ]]; then
    tail -F "$SERIAL_LOG" 2>/dev/null | sed -u 's/^/[vm] /' &
    TAIL_PID=$!
fi

# VM host keys regenerate every boot — pin known_hosts to /dev/null so we never
# record them and never trip REMOTE HOST IDENTIFICATION HAS CHANGED on replays.
# LogLevel=ERROR suppresses the resulting "Permanently added" + host-key warnings
# that would otherwise pollute $SUCCESS_LOG (captures ssh stderr via 2>&1).
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -i "$SSH_KEY"
    -p "$SSH_PORT"
    user@localhost
)
AVC_DENIALS_SH="$(dirname "$0")/../../../scripts/avc-denials.sh"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
log "Waiting for SSH (up to ${TIMEOUT_SSH}s)"
deadline=$(( $(date +%s) + TIMEOUT_SSH ))
until ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
    (( $(date +%s) < deadline )) || die "SSH not available within ${TIMEOUT_SSH}s"
    sleep 5
done
SSH_UP=1
BOOT_SECS=$(( $(date +%s) - START_EPOCH ))
log "SSH up (${BOOT_SECS}s from start)"

# ── Wait for FEDBUILD_READY on serial ─────────────────────────────────────────
# firstboot emits FEDBUILD_READY (success) or FEDBUILD_FAILED <rc> (failure)
# on stdout, which the service routes to ttyS0 via journal+console — so it
# lands directly in $SERIAL_LOG without any SSH round-trip. awk exits 0 on
# READY, 1 on FAILED, and `timeout` returns 124 on wall-clock expiry.
#
# The live [vm] tail (backgrounded above) already streams firstboot progress
# to the operator, so we don't need a spinner or spare journal dump here —
# failures are visible inline as they happen.
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
    0)   : ;;  # READY seen — fall through
    1)   die "FEDBUILD_FAILED marker seen on serial — see [vm] stream above" ;;
    124) die "FEDBUILD_READY not seen within ${TIMEOUT_FIRSTBOOT}s" ;;
    *)   die "serial wait returned unexpected rc=$fb_rc" ;;
esac
FIRSTBOOT_SECS=$(( $(date +%s) - fb_start ))
log "FEDBUILD_READY seen (${FIRSTBOOT_SECS}s)"
# Exported for make baseline-record consumption.
export FIRSTBOOT_SECS

# ── Tool versions (parsed from serial FEDBUILD_TOOL markers) ─────────────────
# firstboot emits one `FEDBUILD_TOOL: label=version` line per tool between
# `tools-begin` and `tools-end` markers. Parsing from the serial log removes
# ~16 SSH round-trips per smoke run and keeps the authoritative tool list in
# one place (firstboot.sh) rather than duplicated here.
#
# Failure modes:
#   <missing>   tool not on PATH in the VM
#   <error>     --version command exited non-zero (unlikely but possible)
#   <empty>     command produced no output (suspect: tool broke post-install)
# Any of the above, or a label with no version separator, counts as a FAIL.
log "Tool versions (from serial FEDBUILD_TOOL markers)"
FAIL=""
while IFS='=' read -r label ver; do
    TOOLS_TOTAL=$((TOOLS_TOTAL+1))
    row "$label" "${ver:-<empty>}"
    case "$ver" in
        ''|'<missing>'|'<error>'|'<empty>') FAIL=1 ;;
        *) TOOLS_OK=$((TOOLS_OK+1)) ;;
    esac
done < <(awk '/^FEDBUILD_TOOL: /{sub(/^FEDBUILD_TOOL: /, ""); print}' "$SERIAL_LOG")
(( TOOLS_TOTAL > 0 )) || die "no FEDBUILD_TOOL markers found on serial — firstboot contract broken"
[[ -z "$FAIL" ]] || die "one or more tools missing or broken"

# ── Dump firstboot journal on success ─────────────────────────────────────────
# Full journal (not just timing summary) so any warnings, brew bundle output,
# and per-section durations are visible alongside the smoke log.
SUCCESS_LOG="${SUCCESS_LOG:-$OUTDIR/smoke-firstboot.log}"
log "Capturing firstboot journal → $SUCCESS_LOG"
ssh "${SSH_OPTS[@]}" "journalctl -u bastion-vm-firstboot --no-pager -o cat" \
    > "$SUCCESS_LOG" 2>&1 || log "  (journal capture failed)"
if [[ -s "$SUCCESS_LOG" ]]; then
    log "Firstboot timing summary"
    sed -n '/Timing summary/,$p' "$SUCCESS_LOG" | sed 's/^/  /'
fi

# ── SELinux enforcement ───────────────────────────────────────────────────────
# VM images must ship with SELinux enforcing + targeted policy. A permissive
# or disabled enforce state means a misconfiguration (kernel args, relabel,
# /etc/selinux/config). Custom labels aren't expected — just the defaults.
log "SELinux"
selinux_mode=$(ssh "${SSH_OPTS[@]}" 'getenforce 2>/dev/null || echo unknown')
selinux_policy=$(ssh "${SSH_OPTS[@]}" 'sestatus 2>/dev/null | awk -F: "/Loaded policy name/{gsub(/ /,\"\",\$2); print \$2}"' || true)
row "enforce" "$selinux_mode"
row "policy"  "${selinux_policy:-<unknown>}"
if [[ "$selinux_mode" != "Enforcing" ]]; then
    FAIL=1
    status "✗" "SELinux not enforcing (got: $selinux_mode)"
fi
if [[ "$selinux_policy" != "targeted" ]]; then
    FAIL=1
    status "✗" "SELinux policy != targeted (got: ${selinux_policy:-<unknown>})"
fi

# AVC denials since boot. Any denial is a policy gap or missing label —
# either way, a misconfigured image that should fail the smoke test.
avc_count=error
avc_list=$(ssh "${SSH_OPTS[@]}" bash -s <"$AVC_DENIALS_SH") && avc_count=$(grep -c . <<<"$avc_list" || true)
row "AVC denials" "$avc_count"
if [[ "$avc_count" != 0 ]]; then
    FAIL=1
    status "✗" "SELinux AVC denials since boot: $avc_count"
    log "Sample denials (first 10):"
    head -10 <<<"$avc_list" | sed 's/^/  /'
fi
[[ -z "$FAIL" ]] || die "SELinux assertions failed"

# ── Fedbuild release file ─────────────────────────────────────────────────────
# /etc/fedbuild-release is emitted by the RPM %post at image-build time.
# Missing file = RPM install regression.
log "Release file"
if ssh "${SSH_OPTS[@]}" 'test -f /etc/fedbuild-release' 2>/dev/null; then
    release_line=$(ssh "${SSH_OPTS[@]}" 'cat /etc/fedbuild-release' 2>/dev/null | awk -F= '/^VERSION=/{v=$2}/^GIT_COMMIT=/{g=$2}END{printf "v%s @ %s", v, substr(g,1,10)}')
    row "release" "$release_line"
else
    FAIL=1
    status "✗" "/etc/fedbuild-release missing"
fi

# ── Ready JSON ────────────────────────────────────────────────────────────────
# /var/log/fedbuild-ready.json is emitted by firstboot.sh on success.
log "Ready JSON"
if ssh "${SSH_OPTS[@]}" 'test -f /var/log/fedbuild-ready.json' 2>/dev/null; then
    ready=$(ssh "${SSH_OPTS[@]}" 'cat /var/log/fedbuild-ready.json' 2>/dev/null)
    if echo "$ready" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
        sub "valid JSON, $(echo -n "$ready" | wc -c) bytes"
    else
        FAIL=1
        status "✗" "ready JSON parse failed"
    fi
else
    FAIL=1
    status "✗" "/var/log/fedbuild-ready.json missing"
fi
[[ -z "$FAIL" ]] || die "release/ready assertions failed"

# ── Boot-time regression check ────────────────────────────────────────────────
BOOT_TIME_BASELINE="${BOOT_TIME_BASELINE:-$(dirname "$0")/boot-time.baseline}"
BOOT_BUDGET_PCT="${BOOT_BUDGET_PCT:-20}"
if [[ ! -f "$BOOT_TIME_BASELINE" ]]; then
    log "no baseline, skipping boot-time check (run: make bless-boot-time)"
else
    baseline_secs=$(cat "$BOOT_TIME_BASELINE")
    limit=$(( baseline_secs + baseline_secs * BOOT_BUDGET_PCT / 100 ))
    if (( FIRSTBOOT_SECS > limit )); then
        die "firstboot time ${FIRSTBOOT_SECS}s exceeds baseline ${baseline_secs}s by >${BOOT_BUDGET_PCT}% (limit=${limit}s)"
    else
        delta_pct=$(awk -v a="$FIRSTBOOT_SECS" -v b="$baseline_secs" 'BEGIN{printf "%.1f", (a-b)*100.0/b}')
        log "boot-time OK: ${FIRSTBOOT_SECS}s (baseline ${baseline_secs}s, ${delta_pct}%, budget +${BOOT_BUDGET_PCT}%)"
    fi
fi

# ── Hardening (auditd + dnf-automatic + Brewfile.lock.json) ───────────────────
log "Hardening"
FAIL=""
auditd_state=$(ssh "${SSH_OPTS[@]}" 'systemctl is-active auditd 2>/dev/null || echo missing')
rules_present=$(ssh "${SSH_OPTS[@]}" '[[ -f /etc/audit/rules.d/99-fedbuild.rules ]] && echo yes || echo no')
dnfauto_state=$(ssh "${SSH_OPTS[@]}" 'systemctl is-enabled dnf5-automatic.timer 2>/dev/null || echo missing')
brewlock_present=$(ssh "${SSH_OPTS[@]}" '[[ -f /var/lib/bastion-vm-firstboot/Brewfile.lock.json ]] && echo yes || echo no')
row "auditd"      "$auditd_state"
row "audit rules" "$rules_present"
row "dnf-auto"    "$dnfauto_state"
row "brew lock"   "$brewlock_present"
[[ "$auditd_state"    == "active"  ]] || { status "✗" "auditd not active (got: $auditd_state)";                           FAIL=1; }
[[ "$rules_present"   == "yes"     ]] || { status "✗" "audit rules file missing";                                         FAIL=1; }
[[ "$dnfauto_state"   == "enabled" ]] || { status "✗" "dnf5-automatic.timer not enabled (got: $dnfauto_state)";           FAIL=1; }
[[ "$brewlock_present" == "yes"    ]] || { status "✗" "Brewfile.lock.json missing";                                       FAIL=1; }
[[ -z "$FAIL" ]] || die "hardening assertions failed"

# ── Assert Claude config (show only failures unless VERBOSE=1) ───────────────
log "Claude config"
CONFIG_MISSING=0
for f in /home/user/.claude/CLAUDE.md /home/user/.claude/settings.json; do
    # shellcheck disable=SC2029
    if ssh "${SSH_OPTS[@]}" "test -f $f" 2>/dev/null; then
        [[ "$VERBOSE" == "1" ]] && status "✓" "$f"
    else
        status "✗" "$f"
        CONFIG_MISSING=1
        FAIL=1
    fi
done
[[ "$CONFIG_MISSING" == 0 && "$VERBOSE" != "1" ]] && sub "2/2 present"
[[ -z "$FAIL" ]] || die "Claude config files missing"

# ── Git SSH signing ───────────────────────────────────────────────────────────
# firstboot generates a per-VM signing key and wires commit.gpgsign=true.
# Verify end-to-end by signing a throwaway commit in a tmp repo.
log "Git signing"
FAIL=""
signing_format=$(ssh "${SSH_OPTS[@]}" 'git config --global gpg.format' 2>/dev/null)
signing_key=$(ssh "${SSH_OPTS[@]}" 'git config --global user.signingkey' 2>/dev/null)
signing_on=$(ssh "${SSH_OPTS[@]}" 'git config --global commit.gpgsign' 2>/dev/null)
row "format"      "${signing_format:-<unset>}"
row "signingkey"  "${signing_key:-<unset>}"
row "gpgsign"     "${signing_on:-<unset>}"
[[ "$signing_format" == "ssh"  ]] || { status "✗" "gpg.format != ssh (got: ${signing_format:-<unset>})"; FAIL=1; }
[[ "$signing_on"     == "true" ]] || { status "✗" "commit.gpgsign != true (got: ${signing_on:-<unset>})"; FAIL=1; }
# End-to-end: init repo, make signed commit, verify with git verify-commit.
# verify-commit's exit code (0 = good) is more stable than grepping
# --show-signature output across git versions.
sign_probe=$(ssh "${SSH_OPTS[@]}" '
    set -e
    d=$(mktemp -d)
    cd "$d"
    git init -q
    git commit --allow-empty -m "smoke signing probe" -q
    if git verify-commit HEAD 2>&1; then
        echo __VERIFIED__
    else
        echo "__UNVERIFIED__: $(git log --show-signature -1 2>&1 | head -3)"
    fi
    rm -rf "$d"
' 2>/dev/null || true)
if echo "$sign_probe" | grep -q "__VERIFIED__"; then
    status "✓" "signed commit verifies"
else
    FAIL=1
    status "✗" "signed commit probe failed: $(echo "$sign_probe" | head -1)"
fi
[[ -z "$FAIL" ]] || die "git signing assertions failed"

# ── Reboot-persistence (optional, SKIP_REBOOT=1 to bypass) ────────────────────
# Verify firstboot truly one-shot: done sentinel mtime unchanged, service not
# re-run, no new AVC denials. Also captures SECONDBOOT_SECS (time from reboot
# request to SSH back up) for baselines.csv trend tracking.
if [[ "$SKIP_REBOOT" == "1" ]]; then
    log "Reboot phase skipped (SKIP_REBOOT=1)"
else
    log "Reboot-persistence"
    pre_mtime=$(ssh "${SSH_OPTS[@]}" 'stat -c%Y /var/lib/bastion-vm-firstboot/done 2>/dev/null || echo 0')
    row "done mtime" "$pre_mtime (pre-reboot)"
    ssh "${SSH_OPTS[@]}" 'sudo systemctl reboot' 2>/dev/null || true
    # SSH session terminates as the machine goes down; ignore exit.
    reboot_start=$(date +%s)
    # Wait for old sshd to stop responding, then for new one to accept.
    # Without the "down" phase we'd race and reconnect to the dying session.
    sleep 3
    log "waiting for SSH back (up to ${TIMEOUT_SECONDBOOT}s)"
    deadline=$(( reboot_start + TIMEOUT_SECONDBOOT ))
    until ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
        (( $(date +%s) < deadline )) || die "VM did not come back within ${TIMEOUT_SECONDBOOT}s"
        sleep 3
    done
    # Wait for system to reach "running" (not still in startup) so service
    # state queries below reflect final post-boot state, not mid-boot.
    # 30s ceiling — degraded units (e.g. dnf5-automatic on a stale
    # network) would otherwise hang the whole smoke indefinitely.
    ssh "${SSH_OPTS[@]}" 'timeout 30 systemctl is-system-running --wait' \
        >/dev/null 2>&1 || true
    SECONDBOOT_SECS=$(( $(date +%s) - reboot_start ))
    export SECONDBOOT_SECS
    row "secondboot" "${SECONDBOOT_SECS}s"

    # Assertions: sentinel persists, no failed sentinel, service not re-run,
    # no new AVC denials.
    post_mtime=$(ssh "${SSH_OPTS[@]}" 'stat -c%Y /var/lib/bastion-vm-firstboot/done 2>/dev/null || echo 0')
    row "done mtime" "$post_mtime (post-reboot)"
    failed_present=$(ssh "${SSH_OPTS[@]}" '[[ -f /var/lib/bastion-vm-firstboot/failed ]] && echo yes || echo no')
    service_state=$(ssh "${SSH_OPTS[@]}" 'systemctl is-active bastion-vm-firstboot.service 2>/dev/null || echo unknown')
    avc2=error
    avc2_list=$(ssh "${SSH_OPTS[@]}" bash -s <"$AVC_DENIALS_SH") && avc2=$(grep -c . <<<"$avc2_list" || true)
    row "failed"      "$failed_present"
    row "service"     "$service_state"
    row "AVC denials" "$avc2"
    FAIL=""
    [[ "$pre_mtime" != "0" && "$post_mtime" == "$pre_mtime" ]] || \
        { status "✗" "done sentinel mtime changed (pre=$pre_mtime post=$post_mtime) — firstboot likely re-ran"; FAIL=1; }
    [[ "$failed_present" == "no" ]] || \
        { status "✗" "failed sentinel appeared after reboot";                                                    FAIL=1; }
    # inactive = ran-and-exited (oneshot RemainAfterExit=no); active = running.
    # Either "activating"/"reloading" means it's re-executing — bad.
    case "$service_state" in
        inactive|active) ;;
        *) status "✗" "firstboot service in unexpected state: $service_state"; FAIL=1 ;;
    esac
    [[ "$avc2" == 0 ]] || \
        { status "✗" "SELinux AVC denials after reboot: $avc2"; FAIL=1; }
    [[ -z "$FAIL" ]] || die "reboot-persistence assertions failed"
fi

# ── Shutdown + final banner ───────────────────────────────────────────────────
# FINISHED=1 tells dump_journal (EXIT trap) to skip — $SUCCESS_LOG is already
# written and the VM is about to go down, so re-dumping would just log
# "connection refused" over a working capture.
FINISHED=1
ssh "${SSH_OPTS[@]}" "sudo poweroff" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

TOTAL_SECS=$(( $(date +%s) - START_EPOCH ))
IMG_SIZE=$(stat -c%s "$IMAGE" 2>/dev/null | awk '{printf "%.1fG", $1/1024/1024/1024}')
log "PASSED  image=$(basename "$IMAGE")  size=${IMG_SIZE:-?}  boot=${BOOT_SECS:-?}s  firstboot=${FIRSTBOOT_SECS:-?}s  secondboot=${SECONDBOOT_SECS:-skip}s  tools=${TOOLS_OK}/${TOOLS_TOTAL}  total=${TOTAL_SECS}s"
