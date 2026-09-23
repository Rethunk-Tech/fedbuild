#!/usr/bin/env bash
# Fails when an extra-rpm is older than the HEAD commit of the repo whose spec
# builds it, or when that spec now builds a package the directory lacks (such
# as a new -selinux subpackage).
#
# Usage: check-extra-rpms.sh EXTRA_RPMS_DIR META_DIR
#
# The source repo is found by spec, not by name: one repo can build several
# RPMs (bastion-edge builds bastion-theatre and bastion-theatre-manager), so
# no repo is named after the RPM. Every git repo directly under META_DIR other
# than fedbuild is searched for tracked *.spec files.
set -euo pipefail

dir=$1
meta=$2

shopt -s nullglob
rpms=("$dir"/*.rpm)
if ((${#rpms[@]} == 0)); then
    echo "check-extra-rpms: no extra-rpms in $dir — skipping"
    exit 0
fi

declare -A have
for rpm in "${rpms[@]}"; do
    have[$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)]=$rpm
done

failed=0
declare -A mapped
for repo in "$meta"/*/; do
    repo=${repo%/}
    [[ "$(basename "$repo")" == fedbuild ]] && continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    head_ts=""
    while IFS= read -r spec; do
        mapfile -t built < <(rpmspec -q --builtrpms --qf '%{NAME}\n' "$repo/$spec" 2>/dev/null |
            grep -Ev -- '-debug(info|source)$' | sort -u)
        present=()
        for name in "${built[@]}"; do
            [[ -n "${have[$name]:-}" ]] && present+=("$name")
        done
        ((${#present[@]} > 0)) || continue
        head_ts=${head_ts:-$(git -C "$repo" log -1 --format=%ct)}
        for name in "${built[@]}"; do
            rpm=${have[$name]:-}
            if [[ -z "$rpm" ]]; then
                echo "MISSING: $name — $repo/$spec builds it, but $dir has none"
                failed=1
                continue
            fi
            mapped[$name]=1
            rpm_ts=$(stat -c%Y "$rpm")
            if ((head_ts > rpm_ts)); then
                echo "STALE: $(basename "$rpm") — $(basename "$repo") HEAD is newer by $((head_ts - rpm_ts))s"
                failed=1
            fi
        done
    done < <(git -C "$repo" ls-files '*.spec')
done

for name in "${!have[@]}"; do
    [[ -n "${mapped[$name]:-}" ]] ||
        echo "WARN: $(basename "${have[$name]}") — no spec under $meta builds it; staleness unchecked"
done

if ((failed)); then
    echo "ERROR: extra-rpms out of date — rebuild them from their source repos"
    exit 1
fi
echo "check-extra-rpms: OK"
