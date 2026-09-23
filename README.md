<h1 align="center">fedbuild</h1>

<div align="center">

[![ci](https://github.com/Rethunk-Tech/fedbuild/actions/workflows/ci.yml/badge.svg)](https://github.com/Rethunk-Tech/fedbuild/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

Reproducible Fedora 44 VM image builder. One pipeline; multiple variants for distinct shipping artifacts.

Each variant produces a small **firstboot RPM** (systemd oneshot for first-boot bootstrap) and a bootable **Fedora 44 image** (`.raw.zst`) built via `image-builder`.

**Supply chain:** reproducible same-tree RPMs (`SOURCE_DATE_EPOCH`), SHA256SUMS cosign-signed (keyless Sigstore), per-variant size budget enforced, optional `extra-rpms/` pickup with `EXPECTED_SHA256` verification, syft SBOM, SLSA v1 provenance.

## Quick Start

```bash
make && make image && make smoke
```

Prerequisites, SSH key setup, VM lifecycle, and variant-specific flows: **[HUMANS.md](HUMANS.md)**.

## Highlights

- **Multi-variant pipeline** — `devbox`, `bastion-edge`, and `bastion-core` from one Makefile-driven tree
- **Reproducible RPMs** — `SOURCE_DATE_EPOCH` locks same-tree byte identity across rebuilds
- **Signed artifacts** — keyless Sigstore cosign on SHA256SUMS
- **Supply-chain visibility** — syft SBOM and SLSA v1 provenance per image
- **Size budgets** — per-variant baselines enforced in CI smoke tests
- **Optional upstream RPM pickup** — `extra-rpms/` with `EXPECTED_SHA256` verification

## Documentation

| Doc | Audience |
| ----- | ---------- |
| **[HUMANS.md](HUMANS.md)** | Quick start, release flow, what first-boot installs |
| **[AGENTS.md](AGENTS.md)** | LLM reference: commands, architecture, blueprint format, gotchas, **reproducibility scope** |
| **[CONTRIBUTING.md](CONTRIBUTING.md)** | PR checklist, file-change map, commit style |
| **[CHANGELOG.md](CHANGELOG.md)** | Auto-generated from Conventional Commits (`make changelog`) |
| **[SECURITY.md](SECURITY.md)** | Vulnerability reporting |
| **[specs/](specs/)** | Active and completed work specs |

## License

MIT — Copyright (c) 2026 Rethunk.Tech, LLC
