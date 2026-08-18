Name:           bastion-vm-firstboot
Version:        0.6.1
Release:        1%{?dist}
Summary:        First-boot setup for coding-agent VM
License:        MIT
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  ShellCheck

Requires:       bash
Requires:       curl
Requires:       systemd

# Commit SHA is passed in from Makefile via --define "_git_commit <sha>".
# Falls back to "unknown" when built outside a git tree.
%global git_commit %{?_git_commit}%{!?_git_commit:unknown}

Source0:        firstboot.sh
Source1:        bastion-vm-firstboot.service
Source2:        devbox-profile.sh
Source3:        user-sudoers
Source4:        agent-claude.md
Source5:        agent-settings.json
Source6:        Brewfile
Source7:        99-fedbuild.rules

%description
Runs once on first boot (as the 'user' account) to install Homebrew
and the development tools listed in the shipped Brewfile (formulae
that are bleeding-edge or have no signed RPM repo with an
always-update URL).

  (cloudflared is installed from its RPM repo and is NOT handled here.
  kubectl/kubernetes-cli uses brew because pkgs.k8s.io requires a
  pinned minor version in its URL, breaking the always-update policy.)

Also installs:
  /etc/profile.d/devbox.sh   — Go / Homebrew / editor environment
  /etc/sudoers.d/user        — passwordless sudo for coding-agent use

# This package installs declared sources directly and has no archive to unpack
# or source to compile.
%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_libexecdir}/%{name}/firstboot.sh
install -Dm644 %{SOURCE1} %{buildroot}%{_unitdir}/%{name}.service
install -Dm644 %{SOURCE2} %{buildroot}%{_sysconfdir}/profile.d/devbox.sh
install -Dm440 %{SOURCE3} %{buildroot}%{_sysconfdir}/sudoers.d/user
install -d %{buildroot}%{_localstatedir}/lib/%{name}
install -Dm644 %{SOURCE4} %{buildroot}%{_datadir}/%{name}/agent-claude.md
install -Dm644 %{SOURCE5} %{buildroot}%{_datadir}/%{name}/agent-settings.json
install -Dm644 %{SOURCE6} %{buildroot}%{_datadir}/%{name}/Brewfile
install -Dm644 %{SOURCE7} %{buildroot}%{_sysconfdir}/audit/rules.d/99-fedbuild.rules

%check
# Lint shell sources at rpmbuild time — failures fail the build.
shellcheck %{SOURCE0} %{SOURCE2}

%post
%systemd_post %{name}.service
# /etc/fedbuild-release — env-file format; consumed by agent + smoke.
# INSTALL_DATE is image-build time (non-reproducible by design: it tells you
# when this image was assembled, not when the RPM was built).
cat > %{_sysconfdir}/fedbuild-release <<EOF
NAME=bastion-vm-firstboot
VERSION=%{version}
RELEASE=%{release}
GIT_COMMIT=%{git_commit}
INSTALL_DATE=$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)
EOF
chmod 0644 %{_sysconfdir}/fedbuild-release

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service
if [ $1 -eq 0 ]; then
    rm -f %{_sysconfdir}/fedbuild-release
fi

%files
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/firstboot.sh
%dir %{_localstatedir}/lib/%{name}
%{_unitdir}/%{name}.service
%{_sysconfdir}/profile.d/devbox.sh
%{_sysconfdir}/sudoers.d/user
%dir %{_datadir}/%{name}
%{_datadir}/%{name}/agent-claude.md
%{_datadir}/%{name}/agent-settings.json
%{_datadir}/%{name}/Brewfile
%ghost %attr(0644,root,root) %{_sysconfdir}/fedbuild-release
%attr(0644,root,root) %{_sysconfdir}/audit/rules.d/99-fedbuild.rules

%changelog
* Sun Apr 26 2026 Damon Blais <damon.blais@gmail.com> - 0.6.1-1
- Package audit rules world-readable and align changelog with the RPM version.

* Fri Apr 17 2026 Damon Blais <damon.blais@gmail.com> - 0.6.0-1
- SBOM generation via syft (CycloneDX + SPDX) — make sbom
- SLSA v1 provenance attestation via cosign — make attest
- SHA256SUMS expanded to cover image + RPM + SBOM + provenance
- Unified baselines tracking: tests/baselines.csv + make baseline-record
- Boot-time regression check with tests/boot-time.baseline + make bless-boot-time
- Idempotency smoke test: tests/smoke-rerun.sh + make smoke-rerun
- Hardening: dnf-automatic (security-only), auditd (root-exec + sudoers watches)
- firstboot dumps /var/lib/bastion-vm-firstboot/Brewfile.lock.json (record, not pin)
- Expanded threat model + verification procedure in SECURITY.md

* Thu Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.4.0-1
- Brewfile replaces per-package brew install loop in firstboot
- Reproducible RPM via SOURCE_DATE_EPOCH (byte-identical builds)
- Image size budget (tests/size.baseline) + bless-size target
- make diff-packages: declared vs installed drift report
- make changelog: git-cliff automation from Conventional Commits

* Thu Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.3.0-1
- Add jq, yq, sqlite, buildah, skopeo to blueprint

* Thu Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.2.0-1
- Sync version to blueprint 0.2.0
- Add BuildRequires: systemd-rpm-macros

* Thu Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.1.0-1
- Bake Claude Code agent configuration into ~/.claude/ via firstboot
- Add CHANGELOG.md; reset versions to 0.1.0
- Initial package: firstboot service, devbox-profile, sudoers, done sentinel
