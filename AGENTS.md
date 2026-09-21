# fedbuild

Builds reproducible Fedora 43 VM images for Bastion. **Multi-variant**: one repo, one pipeline, multiple shipping artifacts via `make VARIANT=<name>`.

Default variant: `devbox` — Bastion Agent sandbox with Homebrew + dev toolchain. Other variants under `variants/`.

## Variants

| Variant | Purpose | Built by |
| --------- | --------- | ---------- |
| `devbox` | Bastion Agent (Claude Code, Gemini CLI) sandbox — Homebrew + dev toolchain | `make` (default) |
| `bastion-edge` | Field-deployable image with `bastion-theatre-manager` daemon (Fedora 43 minimal) | `make VARIANT=bastion-edge image` |
| `bastion-core` | Fedora 43 minimal + full Bastion C2 stack (nested KVM for TheatreManager VMs) | `make VARIANT=bastion-core image` |

Per-variant inputs and smoke: `variants/<name>/README.md`.

## Commands

All targets accept `VARIANT=<name>` (default `devbox`).

```bash
make                  # build RPM + local yum repo (default goal: repo)
make rpm              # build firstboot RPM only
make repo             # copy RPM (+ extra-rpms/) into repo/$(VARIANT) and createrepo
make image            # build Fedora 43 VM image (requires sudo)
make check            # shellcheck + TOML + actionlint + check-versions + check-settings
make check-versions   # assert spec Version matches blueprint version
make check-versions-all  # check-versions across every variants/<name>
make check-settings   # JSON-schema validate agent-settings.json (devbox only)
make check-size       # fail if image > baseline * (1 + SIZE_BUDGET_PCT/100)
make bless-size       # promote image size → variants/<variant>/tests/size.baseline
make bless-boot-time  # FIRSTBOOT_SECS=<n> → variants/<variant>/tests/boot-time.baseline
make shellcheck       # shellcheck SOURCES/*.sh + tests/*.sh
make lint             # rpmlint on built RPM
make validate         # blueprint syntax, SSH key substitution, image-builder target
make smoke            # boot VM (KVM) + variants/<variant>/tests/smoke.sh
make run-vm           # single-VM convenience — defaults VM_VARIANT=bastion-core
make stop-vm / destroy-vm / vm-status / ssh-vm
make smoke-rerun      # re-run smoke against existing image
make diff-packages    # blueprint RPMs vs rpm -qa on running VM
make sign / verify    # cosign keyless-sign / verify SHA256SUMS
make sbom / attest    # syft SBOM + SLSA v1 provenance
make cve-scan         # grype scan SBOM with cve-allowlist.yaml
make brew-drift       # diff brew-versions.txt snapshots (devbox only)
make baseline-record  # append timing row → variants/<variant>/tests/baselines.csv
make check-boot-time  # fail if firstboot_secs > median(last 5) * 1.2
make clean / distclean
make deps             # install createrepo_c (sudo)
make bump-patch / bump-minor / bump-major
make install-hooks / changelog / help
../vm.sh up                          # Bastion parent only (core + edge + /workspace theatre)
../vm.sh up --variant bastion-core   # single-VM escape hatch; standalone clone: make smoke
```

## Architecture

```
fedbuild/
  Makefile                                  # VARIANT dispatch
  variants/<name>/                          # per shipping artifact
    variant.mk                              # PKG_NAME, PKG_BLUEPRINT_NAME, EXTRA_REPOS, PKG_IMAGE_FORMAT
    blueprint.toml
    <pkg-name>-firstboot/{SPECS,SOURCES}/
    tests/{smoke.sh,size.baseline,boot-time.baseline,baselines.csv,cve-allowlist.yaml}
    extra-rpms/                             # optional upstream RPM pickup + EXPECTED_SHA256
    README.md
  keys/authorized_key                       # SSH pubkey (gitignored)
  .github/workflows/ci.yml
  schemas/agent-settings.schema.json
  repo/<variant>/  rpmbuild/  output/<variant>/  specs/active/
```

## Variant anatomy (extended)

`variants/<name>/variant.mk`: `PKG_NAME`, `PKG_BLUEPRINT_NAME`, `PKG_IMAGE_FORMAT`, `EXTRA_REPOS`. Root Makefile errors if `variants/$(VARIANT)/variant.mk` is missing.

`extra-rpms/`: drop upstream RPMs (e.g. bastion-edge consumes `bastion-theatre` + `bastion-theatre-manager` from bastion-edge repo). Optional `EXPECTED_SHA256`, then `make image`.

## Blueprint Format (non-obvious)

osbuild blueprint TOML — <https://osbuild.org/docs/user-guide/blueprint-reference/>

- Packages use `version = "*"` — always-update, no pins
- `[[customizations.user]]` array-of-tables (dotted key + table header = invalid TOML)
- SSH key in `keys/authorized_key` → `make image` generates `blueprint.effective.toml` with substitution
- `[[customizations.files]]` inlines content as escaped `data =`

## Git Identity

Baked `/etc/gitconfig`: `user.name = Bastion Agent`, `user.email = bastion-agent@rethunk.tech`. Override per-repo.

## Gotchas

- `../vm.sh` and `make run-vm` require the Bastion meta-repo parent; a standalone GitHub clone uses `make image && make smoke`
- `make image` needs `sudo`; firstboot `TimeoutStartSec=infinity` (brew 20+ min)
- firstboot runs as `user` (not root); logs: `journalctl -u bastion-vm-firstboot -f`
- Done sentinel: `/var/lib/bastion-vm-firstboot/done`; failed: `.../failed`
- RPM version/release from spec via `sed` in Makefile — edit spec, not Makefile
- `CLAUDE.md` / `GEMINI.md` are `@AGENTS.md` pointers — edit AGENTS only
- Same-tree RPM reproducibility via `SOURCE_DATE_EPOCH`; cross-tree byte-identity not achievable (see § Reproducibility scope)
- `make smoke` needs KVM + built image in `output/`; failures capture journal to `$OUTDIR/smoke-fail.log`
- `auditd` root-exec covers euid=0 only; firstboot/brew/agent (as `user`) not audited
- SLSA provenance is Build L1 — authenticates artifact identity, not build isolation
- `agent-settings.json` schemaVersion pinned; bump JSON + `schemas/agent-settings.v*.schema.json` together

## Reproducibility scope

**Rule:** same-tree determinism, not cross-tree byte-identity.

rpmbuild embeds absolute `_sourcedir` in SRPM header → `Sourcesigmd5` → RPM `Sha1header`/`Sha256header`. Different clone paths produce different RPM bytes with identical payload cpio. Cosign signatures are path-dependent too.

**Guaranteed:** same tree, same git SHA, same SDE, same `_sourcedir` → same RPM bytes across rebuilds. Payload cpio sha256 is path-independent.

**Anti-pattern:** don't gate refactors on cross-tree RPM equality; use same-tree rebuild-determinism (`make rpm; sha256sum; make clean; make rpm; sha256sum; diff`).

## CI

`.github/workflows/ci.yml` on push/PR to `main` in `fedora:43`: shellcheck, rpmlint, actionlint, TOML syntax, `check-versions`, `check-settings`. Local: `make check`.
