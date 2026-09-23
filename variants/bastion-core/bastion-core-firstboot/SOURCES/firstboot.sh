#!/bin/bash
# bastion-core-firstboot — runs once on first boot as root.
#
# Purpose:
#   1. Force-regenerate the Bastion bootstrap bundle and roll the autogen PKI
#      so each VM gets unique cryptographic identity rather than the image-baked
#      defaults generated during RPM %post at image build time.
#   2. Source /var/lib/bastion/install/bootstrap.env and record the per-VM SAI
#      callsign in /var/lib/bastion-core/core-id.
#   3. Write /etc/bastion-core-release (consumed by smoke + operators).
#
# The bastion-core-firstboot.service unit has:
#   ConditionPathExists=!/var/lib/bastion/firstboot-done
# so this runs at most once per VM lifetime. Delete firstboot-done to re-run.
set -euo pipefail

SENTINEL_DIR=/var/lib/bastion-core
SERIAL=/dev/ttyS0
serial() { [[ -w "$SERIAL" ]] && printf '%s\n' "$*" > "$SERIAL" 2>/dev/null || true; }
log()  { echo "[firstboot] $(date -Iseconds) $*"; serial "[firstboot] $*"; }
mark() { printf 'FEDBUILD_MARK: %s\n' "$*"; serial "FEDBUILD_MARK: $*"; }

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log "FAILED (exit $rc) — writing failure sentinel"
        touch "${SENTINEL_DIR}/failed" 2>/dev/null || true
        printf 'FEDBUILD_FAILED %d\n' "$rc"
        serial "FEDBUILD_FAILED $rc"
    fi
}
trap on_exit EXIT

log "Starting"
mark "firstboot-start"

install -d -m 0755 "$SENTINEL_DIR"

# Sidecar service units declare ReadWritePaths=/var/log/bastion; systemd
# namespace setup fails (226/NAMESPACE) if the directory doesn't exist.
install -d -m 0755 /var/log/bastion
chown root:bastion /var/log/bastion
chmod 0775 /var/log/bastion

# ── Roll PKI — generate unique SAI + service-ca per VM ──────────────────────
# bastion-package-init ran during RPM %post (image build time) and already
# populated /var/lib/bastion/install/bootstrap.env with a default SAI/token.
# `--force` rotates that bootstrap bundle, while BASTION_PKI_EPOCH_ROLL=1
# clears the autogen gRPC TLS material so every fresh VM boot gets a unique
# callsign, BASTION_WS_TOKEN, and PKI leaf set.
PACKAGE_INIT=/usr/libexec/bastion-core/bastion-package-init
if [[ ! -x "$PACKAGE_INIT" ]]; then
    log "ERROR: $PACKAGE_INIT not found — is bastion-core RPM installed?"
    exit 1
fi

log "Regenerating bootstrap identity and rolling PKI …"
mark "pki-roll-start"
BASTION_PKI_EPOCH_ROLL=1 "$PACKAGE_INIT" --force
log "Bootstrap identity and PKI rolled"
mark "pki-roll-done"

# ── Provision service-plane CA and sidecar TLS leaves ───────────────────────
# bastion-provision creates /var/lib/bastion/service-ca/{ca.crt,ca.key,
# client.crt,client.key} and issues leaf certs to
# /var/lib/bastion/service-ca/issued/<subject>/{cert.pem,key.pem} for every
# sidecar subject. Must run before any sidecar service starts.
CORE_ROOT=/usr/lib64/bastion-core
PROVISION_TS=$CORE_ROOT/apps/server/src/scripts/bastion-provision.ts
if [[ ! -f "$PROVISION_TS" ]]; then
    log "ERROR: $PROVISION_TS not found — is bastion-core RPM installed?"
    exit 1
fi
log "Provisioning service-plane CA and sidecar TLS leaves …"
mark "service-ca-start"
(cd "$CORE_ROOT/apps/server" && /usr/libexec/bastion-core/bun "$PROVISION_TS") 2>&1 | tee /dev/ttyS0
log "Service-plane CA provisioned"
mark "service-ca-done"

# Grant bastion user ownership of service-ca (created as root by provision).
# Directories: 755 so bastion group members (non-bastion service accounts
# carrying SupplementaryGroups=bastion) can traverse and reach their leaf certs.
# Files: 640 (rw-r-----) — read-service-ca.ts enforces exactly 0600 or 0640;
# 0644 is rejected with "invalid-mode". bastion group read (r) lets service
# accounts with SupplementaryGroups=bastion read ca.crt, client.crt, leaf certs.
chown -R bastion:bastion /var/lib/bastion/service-ca
find /var/lib/bastion/service-ca -type d -exec chmod 755 {} +
find /var/lib/bastion/service-ca -type f \
    \( -name '*.crt' -o -name '*.key' -o -name '*.pem' \) \
    -exec chmod 640 {} + 2>/dev/null || true

# bastion-qemu.service ReadWritePaths requires /var/lib/bastion/qemu at exec time.
install -d -m 0750 /var/lib/bastion/qemu
chown bastion-qemu:bastion-qemu /var/lib/bastion/qemu 2>/dev/null || true


# ── Generate at-rest encryption key for credential-keystore ─────────────────
install -d -m 0755 /etc/bastion
AT_REST_KEY=$(openssl rand -hex 32)
printf 'BASTION_HOST_CREDENTIAL_AT_REST_KEY=%s\n' "$AT_REST_KEY" \
    >> /etc/bastion/bastion.env
# Opt out of bastion-pki-trust gRPC health so the session gate uses the
# permissive no-origins path instead of criticalTrustHealthSnapshot().
# bastion-pki-trust only supports -uds; the mTLS dial fails and the cache
# stays empty, which would cause every session to see no_active_manifest.
printf 'BASTION_TRUST_HEALTH_FROM_GRPC=false\n' >> /etc/bastion/bastion.env
chmod 0640 /etc/bastion/bastion.env
chown root:bastion /etc/bastion/bastion.env
log "Generated BASTION_HOST_CREDENTIAL_AT_REST_KEY; set BASTION_TRUST_HEALTH_FROM_GRPC=false"

# Pre-create images directory so bastion-qemu can read staged qcow2s
# (bastion-edge.qcow2 → TheatreManager VMs, staged post-boot by operator).
# Also grant the operator the shared bastion group so they can read
# root:bastion operator material like /etc/bastion/bastion.env without sudo.
# Mode 0775 + group membership lets the operator stage images directly and
# inspect the live Bastion WS token when driving the browser flow.
install -d -m 0775 /var/lib/bastion/qemu/images
chown bastion-qemu:bastion-qemu /var/lib/bastion/qemu/images 2>/dev/null || true
usermod -aG bastion,bastion-qemu bastion-operator 2>/dev/null || true

systemctl daemon-reload

# ── Create sidecar state and config directories ──────────────────────────────
# Services with ReadWritePaths or ReadOnlyPaths pointing at non-existent paths
# fail systemd namespace setup with 226/NAMESPACE before their ExecStart runs.

# bastion-ironlaw-loader
#   ReadWritePaths=/var/lib/bastion/ironlaw-loader
#   ReadOnlyPaths=/etc/bastion/ironlaw-loader
install -d -m 0750 /var/lib/bastion/ironlaw-loader
chown bastion-ironlaw-loader:bastion-ironlaw-loader /var/lib/bastion/ironlaw-loader 2>/dev/null || true
install -d -m 0755 /etc/bastion/ironlaw-loader

# bastion-intent-ledger-replicator
#   ReadWritePaths=/var/lib/bastion/intent-ledger-replicator
#   ReadOnlyPaths=/etc/bastion/intent-ledger-replicator
install -d -m 0750 /var/lib/bastion/intent-ledger-replicator
chown bastion-intent-ledger-replicator:bastion-intent-ledger-replicator /var/lib/bastion/intent-ledger-replicator 2>/dev/null || true
install -d -m 0755 /etc/bastion/intent-ledger-replicator

log "Created sidecar state directories"

# ── Read generated SAI ───────────────────────────────────────────────────────
BOOTSTRAP_ENV=/var/lib/bastion/install/bootstrap.env
if [[ ! -r "$BOOTSTRAP_ENV" ]]; then
    log "ERROR: $BOOTSTRAP_ENV not written by package-init"
    exit 1
fi
# shellcheck source=/dev/null
source "$BOOTSTRAP_ENV"

sync_bootstrap_identity_env() {
    local tmp filtered
    tmp=$(mktemp)
    filtered="${tmp}.filtered"
    if [[ -f /etc/bastion/bastion.env ]]; then
        grep -vE '^(BASTION_SAI_CALLSIGN|BASTION_SAI_FINGERPRINT|BASTION_SAI_PUBLIC_KEY|BASTION_WS_TOKEN)=' \
            /etc/bastion/bastion.env > "$tmp" || true
    fi
    {
        cat "$tmp"
        printf 'BASTION_SAI_CALLSIGN=%s\n' "$BASTION_SAI_CALLSIGN"
        printf 'BASTION_SAI_FINGERPRINT=%s\n' "$BASTION_SAI_FINGERPRINT"
        printf 'BASTION_SAI_PUBLIC_KEY=%s\n' "$BASTION_SAI_PUBLIC_KEY"
        printf 'BASTION_WS_TOKEN=%s\n' "$BASTION_WS_TOKEN"
    } > "$filtered"
    install -m 0640 -o root -g bastion "$filtered" /etc/bastion/bastion.env
    rm -f "$tmp" "$filtered"
}

sync_bootstrap_identity_env
log "Synced bootstrap identity into /etc/bastion/bastion.env for operator access"

SAI_CALLSIGN="${BASTION_SAI_CALLSIGN:-UNKNOWN}"
log "SAI callsign: $SAI_CALLSIGN"
printf '%s\n' "$SAI_CALLSIGN" > "${SENTINEL_DIR}/core-id"
chmod 0644 "${SENTINEL_DIR}/core-id"
mark "sai-stamped"

# ── Emit release snapshot ────────────────────────────────────────────────────
if [[ -r /etc/bastion-core-release ]]; then
    sed 's/^/  /' /etc/bastion-core-release
else
    log "WARN: /etc/bastion-core-release missing (RPM %post regression)"
fi

log "Done"
printf 'FEDBUILD_READY\n'
serial "FEDBUILD_READY"
