#!/usr/bin/env bash
# smoke.sh — boot the bastion-core qcow2 in QEMU/KVM, SSH in, verify firstboot
#            and all Bastion services.
#
# Usage: bash tests/smoke.sh [output-dir]
#   or:  make VARIANT=bastion-core smoke
#
# No pre-existing SSH key required. An ephemeral ed25519 keypair is generated
# at startup and injected into the VM via the cloud-init NoCloud seed ISO.
# Both halves are deleted on exit.
#
# Requirements:
#   - qemu-system-x86_64 with KVM (/dev/kvm accessible)
#   - edk2-ovmf (UEFI firmware; minimal-raw-zst images are UEFI-only)
#   - genisoimage, mkisofs, or xorrisofs (cloud-init NoCloud seed ISO)
#   - ssh-keygen (ephemeral keypair generation)
#   - A built qcow2 from: make VARIANT=bastion-core image
#
# Environment overrides (all optional):
#   SSH_PORT          host port forwarded to VM :22  (default: 2223)
#   VM_MEM            QEMU RAM in MiB               (default: 8192)
#   VM_SMP            QEMU vCPU count               (default: 4)
#   TIMEOUT_SSH       seconds to wait for SSH       (default: 120)
#   TIMEOUT_FIRSTBOOT seconds to wait for FEDBUILD_READY (default: 300)
#   SERIAL_TAIL       1=stream VM serial to stdout  (default: 1)
#   OVMF_CODE         path to OVMF_CODE.fd          (default: auto-detected)
#   OVMF_VARS_SRC     path to OVMF_VARS.fd template (default: auto-detected)
set -euo pipefail

OUTDIR="${1:-output/bastion-core}"
SSH_PORT="${SSH_PORT:-2223}"
VM_MEM="${VM_MEM:-8192}"
VM_SMP="${VM_SMP:-4}"
TIMEOUT_SSH="${TIMEOUT_SSH:-120}"
TIMEOUT_FIRSTBOOT="${TIMEOUT_FIRSTBOOT:-300}"
SERIAL_TAIL="${SERIAL_TAIL:-1}"
FAIL_LOG="${FAIL_LOG:-$OUTDIR/smoke-fail.log}"
SUCCESS_LOG="${SUCCESS_LOG:-$OUTDIR/smoke-firstboot.log}"
SERIAL_LOG="${SERIAL_LOG:-$OUTDIR/smoke-serial.log}"
QEMU_LOG="${QEMU_LOG:-$OUTDIR/smoke-qemu.log}"

SSH_UP=0
FINISHED=0
QEMU_PID=""
TAIL_PID=""
TMPKEY=""
TMPVARS=""
TMPIMAGE=""
TMPSEEDDIR=""
TMPSEED=""
START_EPOCH=$(date +%s)

log()  { echo "[smoke] $(date -Iseconds) $*"; }
sub()  { printf '  %s\n' "$*"; }
row()  { printf '  %-28s %s\n' "$1" "$2"; }

dump_journal() {
    [[ "$FINISHED" == "1" ]] && return
    [[ "$SSH_UP"   == "1" ]] || { log "SSH never came up — no journal"; return; }
    log "Capturing firstboot journal → $FAIL_LOG"
    mkdir -p "$(dirname "$FAIL_LOG")"
    command ssh "${SSH_OPTS[@]}" \
        "journalctl -u bastion-core-firstboot --no-pager -n 100" \
        > "$FAIL_LOG" 2>&1 || log "  (journal capture failed)"
}

die() {
    log "ERROR: $*"
    echo "[smoke] ERROR: $*" >&2
    [[ -s "$QEMU_LOG"  ]] && sed 's/^/[qemu] /' "$QEMU_LOG"
    [[ -s "$SERIAL_LOG" ]] && { log "Last 40 serial lines:"; tail -40 "$SERIAL_LOG" | sed 's/^/[vm] /'; }
    dump_journal
    exit 1
}

cleanup() {
    dump_journal 2>/dev/null || true
    [[ -n "$TAIL_PID"   ]] && kill "$TAIL_PID"   2>/dev/null || true
    [[ -n "$QEMU_PID"   ]] && kill "$QEMU_PID"   2>/dev/null || true
    [[ -n "$TMPVARS"    ]] && rm -f  "$TMPVARS"
    [[ -n "$TMPIMAGE"   ]] && rm -f  "$TMPIMAGE"
    [[ -n "$TMPSEED"    ]] && rm -f  "$TMPSEED"
    [[ -n "$TMPSEEDDIR" ]] && rm -rf "$TMPSEEDDIR"
    [[ -n "$TMPKEY"     ]] && rm -f  "$TMPKEY" "${TMPKEY}.pub"
}
trap cleanup EXIT

# ── Validate prerequisites ────────────────────────────────────────────────────
[[ -d "$OUTDIR"  ]] || die "$OUTDIR not found — run: make VARIANT=bastion-core image"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found"
command -v ssh-keygen           >/dev/null 2>&1 || die "ssh-keygen not found"
[[ -e /dev/kvm ]] || die "/dev/kvm not accessible — KVM required for bastion-core smoke"

ISOGEN=""
for cmd in genisoimage mkisofs xorrisofs; do
    command -v "$cmd" >/dev/null 2>&1 && { ISOGEN="$cmd"; break; }
done
[[ -n "$ISOGEN" ]] || die "genisoimage/mkisofs/xorrisofs not found — install genisoimage"

OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-}"
for d in /usr/share/edk2/ovmf /usr/share/OVMF /usr/share/qemu; do
    [[ -z "$OVMF_CODE"     && -r "$d/OVMF_CODE.fd" ]] && OVMF_CODE="$d/OVMF_CODE.fd"
    [[ -z "$OVMF_VARS_SRC" && -r "$d/OVMF_VARS.fd" ]] && OVMF_VARS_SRC="$d/OVMF_VARS.fd"
done
[[ -r "$OVMF_CODE"     ]] || die "OVMF_CODE.fd not found (install edk2-ovmf)"
[[ -r "$OVMF_VARS_SRC" ]] || die "OVMF_VARS.fd not found (install edk2-ovmf)"

# ── Locate qcow2 ─────────────────────────────────────────────────────────────
IMAGE=$(find "$OUTDIR" -maxdepth 1 -name '*.qcow2' | sort | tail -1)
[[ -n "$IMAGE" ]] || die "no .qcow2 in $OUTDIR — run: make VARIANT=bastion-core image"
log "Image: $IMAGE"

# ── Ephemeral SSH keypair ─────────────────────────────────────────────────────
# Generated fresh each run; injected via cloud-init; discarded on exit.
# No private key needs to exist in the repo or on disk before smoke runs.
TMPKEY=$(mktemp /tmp/smoke-key-XXXXXX)
rm -f "$TMPKEY"   # ssh-keygen won't overwrite an existing file
ssh-keygen -t ed25519 -f "$TMPKEY" -N "" -C "bastion-core-smoke" -q
SMOKE_PUBKEY=$(cat "${TMPKEY}.pub")
log "Ephemeral smoke keypair generated"

# ── Stage ephemeral copies ────────────────────────────────────────────────────
TMPIMAGE=$(mktemp /tmp/smoke-XXXXXX.qcow2)
TMPVARS=$(mktemp /tmp/smoke-vars-XXXXXX.fd)
log "Copying image (reflink when supported) → $TMPIMAGE"
cp --reflink=auto "$IMAGE" "$TMPIMAGE"
cp "$OVMF_VARS_SRC" "$TMPVARS"

# ── Cloud-init NoCloud seed ISO ───────────────────────────────────────────────
# Injects the ephemeral public key as an authorized key for bastion-operator.
# Also prevents cloud-init from hanging waiting for a network datasource.
TMPSEEDDIR=$(mktemp -d /tmp/smoke-seed-XXXXXX)
cat > "$TMPSEEDDIR/meta-data" <<EOF
instance-id: bastion-core-smoke
local-hostname: bastion-core
EOF
cat > "$TMPSEEDDIR/user-data" <<EOF
#cloud-config
users:
  - name: bastion-operator
    ssh_authorized_keys:
      - ${SMOKE_PUBKEY}
EOF
TMPSEED=$(mktemp /tmp/smoke-seed-XXXXXX.iso)
"$ISOGEN" -output "$TMPSEED" -volid cidata -joliet -rock \
    "$TMPSEEDDIR/meta-data" "$TMPSEEDDIR/user-data" 2>/dev/null
log "Seed ISO with ephemeral pubkey: $TMPSEED"

mkdir -p "$(dirname "$SERIAL_LOG")"
: > "$SERIAL_LOG"
: > "$QEMU_LOG"
log "Serial → $SERIAL_LOG"

# ── Boot VM ───────────────────────────────────────────────────────────────────
log "Booting (SSH → localhost:$SSH_PORT, ${VM_MEM}MiB RAM, ${VM_SMP} vCPUs, +svm)"
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host,+svm \
    -m "$VM_MEM" \
    -smp "$VM_SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$TMPVARS" \
    -drive "file=$TMPIMAGE,format=qcow2,if=virtio" \
    -drive "file=$TMPSEED,format=raw,if=virtio,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log "QEMU PID $QEMU_PID"

sleep 2
kill -0 "$QEMU_PID" 2>/dev/null || { wait "$QEMU_PID" 2>/dev/null || true; die "QEMU exited immediately"; }

[[ "$SERIAL_TAIL" == "1" ]] && { tail -F "$SERIAL_LOG" 2>/dev/null | sed -u 's/^/[vm] /' & TAIL_PID=$!; }

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -i "$TMPKEY"
    -p "$SSH_PORT"
    bastion-operator@localhost
)
AVC_DENIALS_SH="$(dirname "$0")/../../../scripts/avc-denials.sh"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
log "Waiting for SSH (up to ${TIMEOUT_SSH}s)"
deadline=$(( $(date +%s) + TIMEOUT_SSH ))
until command ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
    (( $(date +%s) < deadline )) || die "SSH not available within ${TIMEOUT_SSH}s"
    kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited while waiting for SSH"
    sleep 5
done
SSH_UP=1
BOOT_SECS=$(( $(date +%s) - START_EPOCH ))
log "SSH up (${BOOT_SECS}s from start)"

# ── Wait for FEDBUILD_READY ───────────────────────────────────────────────────
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
    1)   die "FEDBUILD_FAILED seen on serial — firstboot.sh exited non-zero" ;;
    124) die "FEDBUILD_READY not seen within ${TIMEOUT_FIRSTBOOT}s" ;;
    *)   die "serial wait returned rc=$fb_rc" ;;
esac
FIRSTBOOT_SECS=$(( $(date +%s) - fb_start ))
log "FEDBUILD_READY seen (${FIRSTBOOT_SECS}s)"
export FIRSTBOOT_SECS

# ── Capture firstboot journal ─────────────────────────────────────────────────
log "Capturing firstboot journal → $SUCCESS_LOG"
command ssh "${SSH_OPTS[@]}" \
    "journalctl -u bastion-core-firstboot --no-pager" \
    > "$SUCCESS_LOG" 2>&1 || log "  (journal capture failed)"

# ── 1. Firstboot sentinel ─────────────────────────────────────────────────────
log "── firstboot sentinel"
command ssh "${SSH_OPTS[@]}" "test -f /var/lib/bastion/firstboot-done" \
    || die "firstboot-done sentinel missing — ExecStartPost failed"
sub "✓ /var/lib/bastion/firstboot-done"

# ── 2. core-id written ───────────────────────────────────────────────────────
log "── core-id"
CORE_ID=$(command ssh "${SSH_OPTS[@]}" "cat /var/lib/bastion-core/core-id 2>/dev/null || true")
[[ -n "$CORE_ID" ]] || die "core-id empty — PKI roll may have failed"
row "core-id" "$CORE_ID"

# ── 3. SAI callsign in bootstrap.env ─────────────────────────────────────────
log "── bootstrap.env"
command ssh "${SSH_OPTS[@]}" \
    "grep -q BASTION_SAI_CALLSIGN /var/lib/bastion/install/bootstrap.env 2>/dev/null" \
    || die "BASTION_SAI_CALLSIGN missing from bootstrap.env"
sub "✓ BASTION_SAI_CALLSIGN present"

# ── 4. Critical services ──────────────────────────────────────────────────────
log "── critical services"
CRITICAL=(
    bastion-core
    bastion-web
    bastion-credential-keystore
)
for svc in "${CRITICAL[@]}"; do
    state=$(command ssh "${SSH_OPTS[@]}" "systemctl is-active ${svc}.service 2>/dev/null || true")
    if [[ "$state" == "active" ]]; then
        row "✓ ${svc}" "$state"
    else
        die "${svc}.service not active (state=$state)"
    fi
done

# ── 5. Remaining sidecars (warn on failure) ───────────────────────────────────
log "── sidecars"
SIDECARS=(
    bastion-ssh
    bastion-pack-loader
    bastion-pki-trust
    bastion-adcon-engine
    bastion-adcon-mirror
    bastion-ironlaw-loader
    bastion-mfa
    bastion-intent-ledger-replicator
    bastion-qemu
)
WARN_COUNT=0
for svc in "${SIDECARS[@]}"; do
    state=$(command ssh "${SSH_OPTS[@]}" "systemctl is-active ${svc}.service 2>/dev/null || true")
    if [[ "$state" == "active" ]]; then
        row "✓ ${svc}" "$state"
    else
        row "✗ ${svc}" "$state  [WARN]"
        WARN_COUNT=$(( WARN_COUNT + 1 ))
    fi
done

# ── 6. /dev/kvm accessible (nested KVM) ──────────────────────────────────────
log "── nested KVM"
if command ssh "${SSH_OPTS[@]}" "test -e /dev/kvm" 2>/dev/null; then
    sub "✓ /dev/kvm present — nested KVM available"
else
    sub "✗ /dev/kvm missing — host not started with -cpu host,+svm/+vmx  [WARN]"
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

# ── 7. SELinux enforcing ──────────────────────────────────────────────────────
log "── SELinux"
selinux_mode=$(command ssh "${SSH_OPTS[@]}" "getenforce 2>/dev/null || echo unknown")
row "enforce" "$selinux_mode"
[[ "$selinux_mode" == "Enforcing" ]] || { sub "  WARN: not Enforcing"; WARN_COUNT=$(( WARN_COUNT + 1 )); }

# ── 8. AVC denials since boot ─────────────────────────────────────────────────
log "── AVC denials"
AVCS=error
AVC_LIST=$(command ssh "${SSH_OPTS[@]}" bash -s <"$AVC_DENIALS_SH") && AVCS=$(grep -c . <<<"$AVC_LIST" || true)
if [[ "$AVCS" != 0 ]]; then
    row "AVC denials" "$AVCS  [WARN]"
    WARN_COUNT=$(( WARN_COUNT + 1 ))
else
    sub "✓ no AVC denials"
fi

# ── Result ────────────────────────────────────────────────────────────────────
FINISHED=1
log "boot=${BOOT_SECS}s  firstboot=${FIRSTBOOT_SECS}s  warnings=${WARN_COUNT}"
echo "=== bastion-core smoke: PASS (${WARN_COUNT} warning(s)) ==="
