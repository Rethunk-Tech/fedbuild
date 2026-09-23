# fedbuild

## Quick Start

```bash
make deps                                  # install createrepo_c (once)
cp ~/.ssh/id_ed25519.pub keys/authorized_key   # place your SSH pubkey
make                                       # build RPM + local yum repo (default = devbox variant)
make image                                 # build Fedora 44 VM image (needs sudo);
                                           # emits .raw.zst (field dd) + .qcow2 (ADCON runtime)
make smoke                                 # boot + assert firstboot (needs KVM)
make publish-mirror                        # stage qcow2 + SBOM + provenance for ADCON mirror
```

`make help` lists every target. `make variants` lists known variants. Command reference and gotchas: **[AGENTS.md](AGENTS.md)**.

## VM lifecycle

`../vm.sh` is the Bastion meta-repo launcher. It exists when this tree is nested under Bastion (`Bastion/fedbuild`). A standalone clone of `Rethunk-Tech/fedbuild` does not have it — use `make image && make smoke` there. `make run-vm` (and the other `*-vm` targets) fail with that explanation if the parent script is missing.

```bash
../vm.sh up                             # default stack: bastion-core + bastion-edge + /workspace theatre
../vm.sh status                         # stack status and access summary
../vm.sh ssh                            # SSH to bastion-core
../vm.sh down                           # stop the stack
../vm.sh destroy                        # destroy stack run state

../vm.sh up --variant bastion-core      # single-VM escape hatch
```

Equivalent `make` targets when nested: `run-vm`, `stop-vm`, `destroy-vm`, `vm-status`, `ssh-vm` (single VM via `VM_VARIANT`, default `bastion-core`). Use no-arg `../vm.sh` for the full local stack.

- `up` defaults to fresh `output/<variant>/run/`; set `VM_REUSE_STATE=1` to keep prior overlay.
- Default stack: boots core + edge, enrolls TheatreManager, creates/reuses Theatre at `/workspace`, writes bootstrap env to `output/bastion-core/run/bootstrap.env`.
- `devbox`: bootstrap env at `~/.config/bastion/bootstrap.env` inside VM; SSH key from `keys/authorized_key` (override with `VM_SSH_KEY`).

## bastion-core provisioning seed

bastion-core firstboot reads per-host values from the cloud-init NoCloud seed (`cidata` ISO) `meta-data`:

```yaml
instance-id: core-01
local-hostname: bastion-core
bastion_host_network_index: 1
```

`bastion_host_network_index` (integer 1–254) becomes `BASTION_HOST_NETWORK_INDEX` in `/etc/bastion/bastion-qemu.env` and scopes the host's ADCON subnet to `172.22.H.0/24`. Assign every Bastion host a unique value. A seed without the key leaves bastion-qemu inactive with an unmet `ConditionPathExists` (firstboot logs a WARN); an out-of-range value fails firstboot. `../vm.sh` and `make smoke` seed `1`; override with `VM_HOST_NETWORK_INDEX` or `HOST_NETWORK_INDEX` (empty `HOST_NETWORK_INDEX=` smokes the unconfigured state).

## Multiple variants

```bash
make VARIANT=devbox            # default
make VARIANT=bastion-edge image
make variants
```

Per-variant inputs under `variants/<name>/`; outputs under `output/<name>/`.

`bastion-edge` images have no wifi (wired networking only) and no `semanage` or `audit2allow` on the device; build SELinux policy changes off-device. New variant: [AGENTS.md § Variant anatomy](AGENTS.md#variant-anatomy-extended).

## Publishing to the ADCON authoritative-mirror

`make publish-mirror` stages qcow2 + SBOM + provenance into `$(MIRROR_DIR)/vm-images/$(VARIANT)/$(VERSION)/`. Default `MIRROR_DIR=$(OUTDIR)/mirror-stage`; production: `MIRROR_DIR=/var/lib/bastion/adcon-mirror make VARIANT=bastion-edge publish-mirror`.

Symlink landed qcow2 into bastion-core's image dir:

```bash
sudo ln -sfn /var/lib/bastion/adcon-mirror/vm-images/bastion-edge/0.1.0/bastion-edge-0.1.0-x86_64.qcow2 \
             /var/lib/bastion/qemu/images/bastion-edge.qcow2
```

Full spec: meta-repo `specs/active/adcon-runtime-vm-fedbuild-migration/spec.md`.

## What First Boot Installs

- **RPM packages** — [`variants/devbox/blueprint.toml`](variants/devbox/blueprint.toml) `packages = [...]`
- **Brew formulae** — [`variants/devbox/bastion-vm-firstboot/SOURCES/Brewfile`](variants/devbox/bastion-vm-firstboot/SOURCES/Brewfile)
- **npm globals** — `@anthropic-ai/claude-code`, `@google/gemini-cli` (hardcoded in `firstboot.sh`)

Progress: `journalctl -u bastion-vm-firstboot -f` on the VM.

## Release Flow

```bash
make bump-minor       # spec + blueprint version lockstep → runs check-versions
make changelog        # regenerate CHANGELOG.md from Conventional Commits
git commit -am "chore(release): $(yq -p toml -oy '.version' variants/${VARIANT:-devbox}/blueprint.toml)"
git tag "v$(yq -p toml -oy '.version' variants/${VARIANT:-devbox}/blueprint.toml)"
```

## Bless Procedures

After intentional size or performance changes:

```bash
make image && make bless-size && make smoke && make baseline-record
```

Commit `variants/<variant>/tests/size.baseline` and `variants/<variant>/tests/baselines.csv` together.

- `make check-size` fails → investigate with `make diff-packages`; trim or `make bless-size` if intentional.
- `make smoke` boot-time regression → check `journalctl -u bastion-vm-firstboot` inside the VM.

`baselines.csv` columns: `commit,date,build_secs,image_bytes,firstboot_secs,secondboot_secs`. `make check-boot-time` gates on `firstboot_secs`. Jump in `firstboot_secs` → new brew/npm; `secondboot_secs` → new systemd unit.

## Auditd Review

```bash
ausearch -k root-exec    # processes with effective UID 0
ausearch -k sudoers      # writes to /etc/sudoers
```

Auditd `-F euid=0` only — `user` (UID 1000) activity including firstboot/brew/agent is not in `root-exec`.

## Post-First-Boot SBOM

```bash
make sbom             # syft CycloneDX + SPDX from built image
make sign             # cosign keyless-sign SHA256SUMS
make attest           # cosign attest-blob SLSA v1 provenance
```

SBOM is point-in-time for RPM/brew in the image — not npm globals or post-scan brew installs. Verify: **Verifying Artifacts** in `SECURITY.md`.
