# Contributing

## Getting Started

Clone the repo, then follow the [Quick Start in HUMANS.md](HUMANS.md#quick-start).

## Before Submitting a PR

Run all local checks across every variant:

```bash
for v in $(ls variants); do
  make VARIANT=$v check && make VARIANT=$v rpm && make VARIANT=$v lint || break
done
```

Or for a single variant:

```bash
make VARIANT=devbox check && make VARIANT=devbox rpm && make VARIANT=devbox lint
```

All checks must pass for every variant. CI runs the same matrix automatically.

## What Goes Where

Variant-specific changes live under `variants/<variant>/`. Cross-variant infrastructure (Makefile, schemas, generic helpers, CI) lives at the repo root.

| Change | File(s) |
| -------- | --------- |
| New RPM package in a variant | `variants/<variant>/blueprint.toml` — add `[[packages]]` entry |
| New Homebrew formula (devbox only) | `variants/devbox/bastion-vm-firstboot/SOURCES/Brewfile` |
| New env var or PATH entry (devbox only) | `variants/devbox/bastion-vm-firstboot/SOURCES/devbox-profile.sh` |
| New file baked into a variant's image | `variants/<variant>/blueprint.toml` — `[[customizations.files]]` |
| External RPM repo (per variant) | `variants/<variant>/variant.mk` — `EXTRA_REPOS` |
| Variant-specific smoke assertion | `variants/<variant>/tests/smoke.sh` |
| Variant-specific size budget | `variants/<variant>/tests/size.baseline` (use `make VARIANT=<v> bless-size`) |
| Operator-supplied upstream RPM (e.g. bastion-edge) | `variants/<variant>/extra-rpms/<file>.rpm` + entry in `EXPECTED_SHA256` |
| **New variant** | `variants/<name>/{variant.mk,blueprint.toml,<pkg>-firstboot/SPECS+SOURCES,tests/smoke.sh,README.md}` + add to `.github/workflows/ci.yml` matrix |
| Build orchestration (variant-agnostic) | `Makefile` |

## Version Bumping

Use `make bump-patch` / `bump-minor` / `bump-major` — they update spec + blueprint in lockstep and run `check-versions`. Then `make changelog` regenerates `CHANGELOG.md` from Conventional Commits (requires `brew install git-cliff`).

## Commit Style

Conventional commits: `type(scope): subject`. Body explains motivation, not file list. `git-cliff` groups them into changelog sections (`feat`→Added, `fix`→Fixed, `refactor`/`perf`→Changed, `docs`→Docs, `test`→Tests, `ci`→CI; `chore` is skipped).

## Questions

Open a [discussion](https://github.com/Rethunk-Tech/fedbuild/discussions) or [issue](https://github.com/Rethunk-Tech/fedbuild/issues).
