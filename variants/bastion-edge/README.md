# bastion-edge

Field-deployable Bastion edge image — Fedora 43 minimal + `bastion-theatre-manager` + `bastion-theatre`. Boots directly into the TheatreManager daemon that connects to Bastion over gRPC + mTLS.

## Output

| Artifact | What it is |
| --- | --- |
| `bastion-edge-firstboot-X.Y.Z-1.fc43.noarch.rpm` | Tiny firstboot unit: stamps `/var/lib/bastion-edge/edge-id` from cidata or `/etc/machine-id`, then exits. Built by fedbuild. |
| `fedora-43-bastion-edge-X.Y.Z-*.x86_64.raw.zst` | Bootable image with `bastion-theatre` + `bastion-theatre-manager` + firstboot baked, `bastion-theatre-manager.service` enabled. |

## Inputs (operator-supplied)

Unlike `devbox` (self-contained), the `bastion-edge` variant requires **two RPMs built elsewhere** dropped into `extra-rpms/` before `make image`:

1. `bastion-theatre-X.Y.Z-N.fc43.x86_64.rpm` — Node payload; no systemd unit
2. `bastion-theatre-manager-X.Y.Z-N.fc43.x86_64.rpm` — the daemon; ships `bastion-theatre-manager.service` + `theatremanager` sysuser

Produce them from the [`bastion-edge` repo](https://github.com/Rethunk-Tech/bastion-edge):

```bash
cd ~/src/bastion-edge
bun run release:rpm:theatre            # → packaging/rpm/rpmbuild/RPMS/x86_64/bastion-theatre-*.rpm
bun run release:rpm:theatre-manager    # → packaging/rpm/rpmbuild/RPMS/x86_64/bastion-theatre-manager-*.rpm

cp packaging/rpm/rpmbuild/RPMS/x86_64/bastion-theatre{,-manager}-*.rpm \
   ~/fedbuild/variants/bastion-edge/extra-rpms/
```

`bastion-theatre-manager` has `Requires: bastion-theatre = %{version}-%{release}` — the two RPMs **must** be version-matched. dnf will refuse the image build otherwise.

## Supply-chain pinning (F7a)

`extra-rpms/EXPECTED_SHA256` lists one `<sha256>  <rpm-filename>` pair per dropped RPM. `make VARIANT=bastion-edge repo` runs `sha256sum -c` before `createrepo` and fails on any mismatch. Populate it when you drop the RPMs:

```bash
cd ~/fedbuild/variants/bastion-edge/extra-rpms
sha256sum bastion-theatre*.rpm bastion-theatre-manager*.rpm > EXPECTED_SHA256
```

fedbuild does **not** vouch for the original provenance of these RPMs — that's the caller's responsibility. This file only pins what was accepted into fedbuild's local repo on this machine.

## Build

```bash
cp ~/.ssh/id_ed25519.pub ../../keys/authorized_key   # one-time
# drop RPMs + populate EXPECTED_SHA256 (see above)
make VARIANT=bastion-edge rpm        # firstboot RPM only (works without extra-rpms)
make VARIANT=bastion-edge image      # full image (sudo; requires extra-rpms populated)
make VARIANT=bastion-edge smoke      # KVM boot + assertion sweep
```

## Smoke assertions

`tests/smoke.sh` asserts:

- VM SSH-up as `edge-operator`
- `FEDBUILD_READY` marker on serial console
- `systemctl is-active bastion-theatre-manager` → `active`
- `/var/lib/bastion-edge/done` exists; `failed` absent; `edge-id` populated
- **No leakage:** `/home/linuxbrew` absent, `~/.claude/` absent (dev tooling must not bleed into edge)
- `node` on PATH (bastion-theatre-manager requires nodejs >= 22)
- SELinux enforcing, zero AVC denials since boot
- Reboot persistence: `bastion-theatre-manager` stays active on second boot; firstboot does not re-run

See `tests/smoke.sh` for the full list.

## What's NOT in this variant

By design:

- **No Homebrew** — edge images are hardened appliances, not dev sandboxes
- **No AI CLIs** (Claude, Gemini) — agent code lives on the development variant (`devbox`), not on the edge
- **No Bun global** — TheatreManager bundles its Node payload
- **No wifi, installer, or `semanage`/`audit2allow`** — `trim-image.sh` removes initial-setup/anaconda (taking `policycoreutils-python-utils` with it), the wifi stack, and `glibc-all-langpacks` (`glibc-langpack-en` stays)
- **No VS Code / cloudflared repos** — strictly upstream Fedora + local fedbuild repo

If you want all of the above, build `VARIANT=devbox` instead.

## Related

- Spec: multi-variant-refactor (closed; see [specs index](../../specs/index.md))
- Downstream consumer: Bastion meta-repo `specs/active/packaging-vm-retirement/` — replaces the qcow2-overlay harness with this image flow
- TheatreManager docs: [`bastion-edge` repo `AGENTS.md`](https://github.com/Rethunk-Tech/bastion-edge/blob/main/AGENTS.md)
