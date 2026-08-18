Name:           bastion-edge-firstboot
Version:        0.1.0
Release:        1%{?dist}
Summary:        First-boot setup for Bastion edge VM
License:        MIT
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  ShellCheck

Requires:       bash
Requires:       systemd
Requires:       bastion-theatre-manager

# Commit SHA passed via --define "_git_commit <sha>" from the root Makefile.
%global git_commit %{?_git_commit}%{!?_git_commit:unknown}

Source0:        firstboot.sh
Source1:        bastion-edge-firstboot.service

%description
Runs once on first boot to stamp the edge VM with a stable edge-id — sourced
from cloud-init NoCloud metadata when present (%{?_tmpfilesdir} populated
by cidata), otherwise derived from /etc/machine-id. Writes the id to
/var/lib/bastion-edge/edge-id so bastion-theatre-manager and downstream
Bastion control-plane code can identify the host.

This RPM is minimal by design. It does NOT install Node, npm, Homebrew, or
any development tooling — the edge variant is a hardened field-deployable
appliance, not a dev sandbox (see variants/devbox/ for that).

# This package installs declared sources directly and has no archive to unpack
# or source to compile.
%prep

%build

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_libexecdir}/%{name}/firstboot.sh
install -Dm644 %{SOURCE1} %{buildroot}%{_unitdir}/%{name}.service
install -d %{buildroot}%{_localstatedir}/lib/bastion-edge

%check
shellcheck %{SOURCE0}

%post
%systemd_post %{name}.service
# /etc/bastion-edge-release — env-file; consumed by smoke + by operators
# debugging field deployments. GIT_COMMIT is fedbuild's commit, not the
# bastion-theatre-manager RPM version (that's in rpm -qi bastion-theatre-manager).
cat > %{_sysconfdir}/bastion-edge-release <<EOF
NAME=bastion-edge-firstboot
VERSION=%{version}
RELEASE=%{release}
GIT_COMMIT=%{git_commit}
INSTALL_DATE=$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)
EOF
chmod 0644 %{_sysconfdir}/bastion-edge-release

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service
if [ $1 -eq 0 ]; then
    rm -f %{_sysconfdir}/bastion-edge-release
fi

%files
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/firstboot.sh
%dir %{_localstatedir}/lib/bastion-edge
%{_unitdir}/%{name}.service
%ghost %attr(0644,root,root) %{_sysconfdir}/bastion-edge-release

%changelog
* Fri Apr 17 2026 Damon Blais <damon.blais@gmail.com> - 0.1.0-1
- Initial: edge-id stamp from cidata or machine-id; oneshot service; %%post
  writes /etc/bastion-edge-release.
