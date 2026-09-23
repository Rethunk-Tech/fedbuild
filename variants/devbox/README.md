# devbox

Bastion Agent (Claude Code, Gemini CLI) sandbox image — Fedora 44 minimal + Homebrew + dev toolchain. Default fedbuild variant; the artifact you get from running `make` (no `VARIANT=` flag).

## Output

| Artifact | What it is |
|---|---|
| `bastion-vm-firstboot-X.Y.Z-1.fc44.noarch.rpm` | Reproducible RPM containing the firstboot systemd oneshot, baked agent settings (`~/.claude/`), Brewfile, devbox profile (PATH/GOPATH/Homebrew shellenv), sudoers stanza |
| `fedora-44-devbox-X.Y.Z-*.x86_64.raw.zst` | Bootable Fedora 44 image with all packages from `blueprint.toml` baked + `bastion-vm-firstboot.service` enabled to run on first boot |

## Build

```bash
cp ~/.ssh/id_ed25519.pub ../../keys/authorized_key   # one-time
make                                                  # RPM + local repo
make image                                            # full image (sudo, ~5 min)
make smoke                                            # KVM boot + assertion sweep
```

`VARIANT=devbox` is the default for every `make` target — explicit `VARIANT=devbox` is allowed but redundant.

`../vm.sh up` also prepares a reusable Bastion dev bootstrap env under
`~/.config/bastion/bootstrap.env` inside the VM, mirrors it to
`output/devbox/run/bootstrap.env`, and prints the WS token plus bootstrap-env
guidance in the host-side summary. If Bastion is already running manually
inside the VM, rerunning `up` also prints the local tunnel command.

## Inputs

- `blueprint.toml` — package list + image customisations (osbuild blueprint format)
- `bastion-vm-firstboot/SPECS/bastion-vm-firstboot.spec` — RPM spec
- `bastion-vm-firstboot/SOURCES/` — firstboot.sh, service unit, devbox profile, sudoers, baked agent settings, Brewfile, auditd rules
- `tests/smoke.sh` — devbox-specific smoke (asserts firstboot done sentinel, brew bundle complete, agent settings baked)
- `tests/size.baseline` — image size budget (current: ~1.6 GiB)
- `tests/boot-time.baseline` — firstboot wall-clock reference
- `tests/baselines.csv` — per-commit timing history

No `extra-rpms/` for devbox — everything comes from upstream Fedora repos + Microsoft VS Code repo + Cloudflare cloudflared repo (declared in `variant.mk`'s `EXTRA_REPOS`).

## Smoke assertions

`tests/smoke.sh` asserts:
- VM SSH-up
- `bastion-vm-firstboot.service` ran to completion (`/var/lib/bastion-vm-firstboot/done` exists, no `failed`)
- Homebrew installed under `/home/linuxbrew/`
- `Brewfile.lock.json` produced
- Agent config baked at `~user/.claude/CLAUDE.md` + `settings.json`
- Tools on PATH: `claude`, `gemini`, `git`, `gh`, `node`, `go`

See `tests/smoke.sh` for the full list.

## Update flow

```bash
make bump-patch       # bumps spec + blueprint version in lockstep
make changelog        # regenerate top-level CHANGELOG.md from Conventional Commits
make image && make smoke
make bless-size       # if image size shifted intentionally
```
