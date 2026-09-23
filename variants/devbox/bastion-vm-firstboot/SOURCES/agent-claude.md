# Bastion Agent

Coding agent running in an isolated Fedora 44 VM (fedbuild).

## Environment

- **Sudo**: passwordless (`NOPASSWD: ALL`) — VM is sandboxed, intentional
- **Network**: outbound only; no inbound exposure
- **User**: `user` (UID 1000); home `/home/user`
- **Identity file**: `/etc/fedbuild-release` — `VERSION`, `GIT_COMMIT`, `INSTALL_DATE`
- **Readiness**: `/var/log/fedbuild-ready.json` — single-line JSON with tool versions + firstboot duration

## Tools

Installed via RPM / Homebrew / npm — use these, don't install ad-hoc:

| Category | Tools |
|----------|-------|
| VCS | git, gh |
| Runtimes | go, node, bun, yarn, uv (Python) |
| Search | rg, fd, tokei |
| Containers | podman, kubectl, helm |
| AI CLIs | claude, gemini |
| Linters | shellcheck, actionlint, semgrep, buf |
| Cloud | supabase, cloudflared |

## Git Identity

`/etc/gitconfig`: `Bastion Agent <bastion-agent@rethunk.tech>` — override per-repo:
`git config user.name "..." && git config user.email "..."`

## Defaults

- Editor: `nvim`; Pager: `less`
- Python: `uv` (not pip/poetry)
- Prefer `rg` over grep, `fd` over find
- Commit per logical unit; Conventional Commits (`type(scope): subject`)
- Long-running work belongs in a `tmux`/`screen` session if available

## Workflow guidance

1. **Sudo freely** inside the VM — there is no privileged state to protect. Installing system packages, editing `/etc/*`, rebooting: all fair game.
2. **Outbound network works; inbound does not.** Don't try to expose services to the host; use Cloudflare Tunnel (`cloudflared`) if a public URL is needed.
3. **Scratch space**: use `/tmp/agent-*` or a dedicated `~/scratch/` directory; never clutter repo roots.
4. **Logs for post-mortem**: firstboot log at `journalctl -u bastion-vm-firstboot`; readiness JSON at `/var/log/fedbuild-ready.json`. Reference these when diagnosing env issues.
5. **Commit early, commit often** — a dirty working tree is your only state loss risk if the VM is reset.

## Reporting identity

When asked what VM this is, read `/etc/fedbuild-release` and/or `/var/log/fedbuild-ready.json`. Don't guess from hostname or kernel.
