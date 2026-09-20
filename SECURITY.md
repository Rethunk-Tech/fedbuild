# Security

## Reporting Issues

Open an issue at <https://github.com/Rethunk-Tech/fedbuild/issues>. For suspected
credential leaks or supply-chain concerns, email `damon.blais@gmail.com`
directly before filing a public issue.

## Credentials

- `keys/` is gitignored — SSH public keys are never committed.
- `blueprint.toml` retains a `CHANGEME` placeholder; the real key is
  substituted at build time into `blueprint.effective.toml` (also gitignored).
- `/etc/sudoers.d/user` grants `NOPASSWD: ALL` to `user`. This is intentional
  (see trust boundary below) but means an attacker with `user` shell access
  has root.

## Threat Model

### Assets protected

1. **Host system** running the VM (developer laptop / CI runner).
2. **Source tree + repo credentials** the agent is given access to during a
   session.
3. **Outbound reputation / cost**: API calls charged to the operator's
   accounts (Anthropic, Google, GitHub, cloud).

### In scope

| Threat | Mitigation |
| -------- | ------------ |
| VM escape to host | Relies on QEMU/KVM isolation; host runs latest Fedora. Agent has no access to host sockets or filesystem beyond explicitly forwarded ports. |
| Malicious upstream package | All RPMs signed (Fedora, Microsoft, Cloudflare GPG). Homebrew + npm installs are trust-on-first-use; `brew` bottles are checksummed but not GPG-signed. Versions pinned to `*` = "always update" → moving target. `make sbom` emits CycloneDX + SPDX post-install inventory for forensic diff; `Brewfile.lock.json` records per-boot resolution. Detection, not prevention. |
| Firstboot tampering | RPM reproducible (SOURCE_DATE_EPOCH). `%check` runs `shellcheck`. Image `SHA256SUMS` (image + RPM + SBOM + provenance) signed via `cosign` (Sigstore keyless). SLSA v1 provenance attestation via `make attest` anchors build output to source commit. |
| Agent prompt injection from attacker-controlled content | Agent sandbox is the VM itself: if the agent is tricked into running destructive commands, the blast radius is one VM. No durable state crosses VM sessions. |
| Credential exfiltration | Outbound network is unrestricted (see limits, below). Do not inject long-lived credentials (prod DB, cloud admin) into the VM. Use short-lived, scoped tokens. |

### Out of scope

- **Multi-tenant isolation inside the VM** — there is only one `user` and
  root is a sudo away. Do not run hostile code alongside trusted code.
- **Kernel-level isolation between agent sessions** — use a fresh VM
  snapshot per session if you need this.
- **Side-channel attacks from the guest** against the host CPU (Spectre-class).
  Mitigated only by the host's microcode/kernel; fedbuild does not pin these.
- **Supply-chain attacks against Homebrew formulae or npm packages installed
  at firstboot**. SBOM + `Brewfile.lock.json` enable detection but not
  prevention; no pinning, no per-formula signing. See "Known Limits".

## Trust Boundary

```
┌──────────────────────────────────────────────────────────────────┐
│ Host OS (developer laptop / CI)                                 │
│  ─ trusts: fedbuild build toolchain, QEMU/KVM, OVMF, cosign      │
│  ─ exposes to VM: forwarded SSH port, optional mounted volumes   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Guest VM (fedora-43-devbox)                               │  │
│  │  ─ user=user, NOPASSWD sudo                                │  │
│  │  ─ trusts: baked RPM, Fedora repos, MS/Cloudflare RPMs,    │  │
│  │           Homebrew formulae, npm globals                   │  │
│  │  ─ network: outbound unrestricted, inbound SSH only        │  │
│  │                                                            │  │
│  │   ┌────────────────────────────────────────────────────┐   │  │
│  │   │ Agent process (claude / gemini CLI)               │   │  │
│  │   │  ─ runs as user                                    │   │  │
│  │   │  ─ permission-gated Bash commands via              │   │  │
│  │   │     ~/.claude/settings.json                        │   │  │
│  │   │  ─ has full sudo via parent shell                  │   │  │
│  │   └────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

- **Host → VM**: one-way; host treats VM as untrusted. Never mount host
  secrets read-write into the VM.
- **VM → Host**: no direct access. Agent cannot reach host localhost
  services unless the host explicitly forwards them in.
- **Agent → VM**: agent can escalate to root trivially. Do not rely on
  the `permissions.allow` list for security — it is for ergonomics, not
  sandboxing.

## Known Limits

- **SBOM scope** — `make sbom` runs `syft` on the built image; it records
  RPM/brew/npm packages present, not their upstream source integrity.
- **SLSA Build Level: L1** — `cosign attest-blob` authenticates "this output
  came from this source commit via this build invocation". It does NOT satisfy
  L2: the builder is not hardened or tenant-isolated, the build is not
  hermetic, and provenance is generated by the same process that ran the
  build. Upgrading to L2 requires a hardened hosted builder (e.g. GitHub
  Actions SLSA generator + hardened runner).
- **`Brewfile.lock.json` is a record, not a pin** — captures what `brew
  bundle` resolved on a given boot. Next boot still resolves `latest`; the
  lock file is not read by `brew bundle` unless `--frozen` is passed
  explicitly. Useful for forensic diff, not defense.
- **`auditd` does not cover firstboot tooling** — the root-exec rule uses
  `-F auid=0`. `firstboot.sh`, brew, npm, and the agent all run as `user`
  (UID 1000) — none appear in the audit trail. Rules cover post-boot
  privileged activity only.
- **`dnf5-automatic` is install-only** — security-classified RPM updates are
  downloaded and applied automatically; kernel updates require a manual
  reboot. The operator is responsible for rebooting after kernel patches.
- **Image is not reproducible** — the RPM build is reproducible
  (SOURCE_DATE_EPOCH); the image is not. `INSTALL_DATE` in
  `/etc/fedbuild-release`, brew install timestamps, and firstboot-generated
  state differ across builds.
- **Moving-target versions** — every rebuild can pull different RPM/brew/npm
  versions. SBOM captures the snapshot; it does not prevent drift.
- **Homebrew on Linux** installs via `curl | bash`. The installer URL is
  HTTPS-fetched but not pinned to a known SHA.
- **Agent npm globals** (`@anthropic-ai/claude-code`, `@google/gemini-cli`)
  install `latest` at firstboot time.
- **No egress filtering inside VM** — outbound network unrestricted within
  the guest. Egress controls depend on host/hypervisor network config.

## VM Security Model (summary)

The built VM is designed for isolated local use:

- No external IP or inbound network exposure (beyond forwarded SSH).
- `NOPASSWD: ALL` sudo for `user` is intentional — the VM is a sandboxed
  coding agent, not a multi-user system.
- Firstboot service runs as `user` (not root), with selected systemd
  sandboxing (`PrivateTmp`, `ProtectKernel*`, etc.).
- SELinux enforcing + targeted policy (asserted by `make smoke`).
- SSH hardened: key-only auth, no root login, no X11, allowlist = `user`.
- `auditd` watches root-exec + sudoers writes (see Post-Install Integrity
  Checks below).
- `dnf5-automatic` applies security-classified RPM updates (install-only).

## Post-Install Integrity Checks

### auditd

Rules loaded at boot from `/etc/audit/rules.d/99-fedbuild.rules`:

| Rule | Key | Covers | Does NOT cover |
| ------ | ----- | -------- | ---------------- |
| `-a always,exit -F arch=b64 -S execve -F auid=0` | `root-exec` | exec where audit-UID is root | anything run by `user` (UID 1000), including firstboot + brew + agent |
| `-w /etc/sudoers -p wa` | `sudoers` | writes/attribute changes to `/etc/sudoers` | `/etc/sudoers.d/*` unless individual watch rules added |
| `-w /etc/sudoers.d/ -p wa` | `sudoers` | writes to `/etc/sudoers.d/` directory | — |
| `-w /root/ -p wa` | `root-writes` | writes under `/root/` | — |

Logs at `/var/log/audit/audit.log`. Query:

```bash
ausearch -k root-exec
ausearch -k sudoers
ausearch -k root-writes
```

### dnf5-automatic (security-only)

`/etc/dnf/dnf5-plugins/automatic.conf` configured with
`upgrade_type = security`, `apply_updates = yes`. Runs via
`dnf5-automatic.timer`.

- Downloads + installs security-classified RPM updates automatically.
- Does NOT auto-reboot — kernel updates staged, operator must reboot.
- Does NOT install non-security updates.
- Package: `dnf5-plugin-automatic` (Fedora 43 uses dnf5-native
  `automatic.conf` and `dnf5-automatic.timer`; `dnf-automatic` remains
  resolvable via `Provides:` but
  ships no `.timer` file).

Check: `systemctl status dnf5-automatic.timer` /
`journalctl -u dnf5-automatic`.

### Brewfile.lock.json (per-boot record)

`firstboot.sh` runs `brew bundle dump` after the bundle install completes,
writing `/var/lib/bastion-vm-firstboot/Brewfile.lock.json`. **Record, not
pin** — next boot re-resolves `latest`. Diff between boots to detect drift:

```bash
diff Brewfile.lock.json.boot1 Brewfile.lock.json.boot2
```

## Verifying Artifacts

After `make sign` + `make sbom` + `make attest`:

```bash
# Verify SHA256SUMS signature (covers image + RPM + SBOM + provenance)
CERT_IDENTITY=<signer-OIDC-subject> \
CERT_OIDC_ISSUER=https://token.actions.githubusercontent.com \
  make verify

# Cross-check artifact checksums
cd output && sha256sum -c SHA256SUMS

# Inspect SBOM (CycloneDX)
jq '.components[] | {name, version}' output/sbom.cdx.json

# Verify SLSA provenance
cosign verify-blob-attestation \
  --certificate output/provenance.pem \
  --signature output/provenance.sig \
  --type slsaprovenance1 \
  output/*.raw.zst
```
