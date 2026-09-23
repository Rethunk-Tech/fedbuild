#!/usr/bin/env bash
# Build all Bastion RPMs needed for the bastion-core fedbuild variant and copy
# them into variants/bastion-core/extra-rpms/.
#
# Usage:
#   ./scripts/build-extra-rpms.sh [--version X.Y.Z] [--parallel]
#
# Run from fedbuild/ root or the variant directory. The Bastion meta-repo
# sibling clones must be present under the parent directory.
set -euo pipefail

VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_ROOT="$(cd "${VARIANT_DIR}/../../.." && pwd)"   # Bastion meta-repo root
EXTRA_RPMS="${VARIANT_DIR}/extra-rpms"
# Fedora's go.env sets GOTOOLCHAIN=local; auto lets each go.mod fetch the toolchain it names.
export GOTOOLCHAIN=auto

VERSION="${BASTION_RPM_VERSION:-0.0.0}"
PARALLEL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --parallel)  PARALLEL=true; shift ;;
    *)           echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Sidecar Go repos ─────────────────────────────────────────────────────────
GO_SIDECARS=(
  bastion-credential-keystore
  bastion-ssh
  bastion-pack-loader
  bastion-pki-trust
  bastion-adcon-engine
  bastion-qemu
  bastion-adcon-mirror
  bastion-ironlaw-loader
  bastion-mfa
  bastion-intent-ledger-replicator
)

build_sidecar() {
  local name="$1"
  local repo_path="${META_ROOT}/${name}"
  local spec_dir="${repo_path}/packaging/rpm"
  if [[ ! -d "$spec_dir" ]]; then
    echo "SKIP: ${name} — no packaging/rpm/ dir" >&2
    return 0
  fi
  echo "Building ${name} …"
  rm -f "${EXTRA_RPMS}/${name}-"*.rpm

  # Build inline rather than via the sidecar's build-rpm.sh so we can keep the
  # vendor/ directory in the source tarball.  The sidecar build-rpm.sh strips
  # vendor/ and then relies on GOPROXY to re-fetch modules, but bastion-common
  # and other local-replace siblings are not publishable to proxy.golang.org.
  # Keeping vendor/ lets rpmbuild satisfy all imports offline.
  local WORK_DIR
  WORK_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${WORK_DIR}'" RETURN

  local RPMBUILD_ROOT="${WORK_DIR}/rpmbuild"
  mkdir -p "${RPMBUILD_ROOT}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

  local SRC_DIR="${WORK_DIR}/${name}-${VERSION}"
  (cd "$repo_path" && cp -a . "${SRC_DIR}/")
  # Vendor from the repo so its ../bastion-* replaces resolve, but write into the
  # staged copy: a vendor/ left in the repo breaks its own go build.
  rm -rf "${SRC_DIR}/vendor"
  (cd "$repo_path" && GOWORK=off go mod vendor -o "${SRC_DIR}/vendor")

  tar -C "${WORK_DIR}" -czf \
      "${RPMBUILD_ROOT}/SOURCES/${name}-${VERSION}.tar.gz" \
      "${name}-${VERSION}"

  cp "${spec_dir}/${name}.spec" "${RPMBUILD_ROOT}/SPECS/"
  for f in "${name}.service" "${name}.sysusers"; do
    [[ -f "${spec_dir}/${f}" ]] && cp "${spec_dir}/${f}" "${RPMBUILD_ROOT}/SOURCES/" || true
  done

  GOWORK=off \
    rpmbuild -bb \
    --define "_topdir ${RPMBUILD_ROOT}" \
    --define "rpm_version ${VERSION}" \
    --define "rpm_release 1" \
    "${RPMBUILD_ROOT}/SPECS/${name}.spec"

  find "${RPMBUILD_ROOT}/RPMS" -name "${name}-*.rpm" -exec cp {} "${EXTRA_RPMS}/" \;
}

# ── bastion-core (Node.js, different build flow) ─────────────────────────────
build_bastion_core() {
  local repo_path="${META_ROOT}/bastion-core"
  echo "Building bastion-core …"
  rm -f "${EXTRA_RPMS}/bastion-core-"*.rpm
  (
    cd "$repo_path"
    RPM_VERSION="${VERSION}" \
    BASTION_RPM_OUT_DIR="${EXTRA_RPMS}" \
      packaging/rpm/build-rpm.sh
    # build-rpm.sh does not honor BASTION_RPM_OUT_DIR; copy only the version just built
    find packaging/rpm/rpmbuild/RPMS -name "bastion-core-${VERSION}-*.rpm" \
      -exec cp -v {} "${EXTRA_RPMS}/" \;
  )
}

mkdir -p "${EXTRA_RPMS}"

if [[ "$PARALLEL" == true ]]; then
  pids=()
  for svc in "${GO_SIDECARS[@]}"; do
    build_sidecar "$svc" &
    pids+=($!)
  done
  build_bastion_core &
  pids+=($!)
  for pid in "${pids[@]}"; do wait "$pid"; done
else
  for svc in "${GO_SIDECARS[@]}"; do
    build_sidecar "$svc"
  done
  build_bastion_core
fi

echo ""
echo "Built RPMs in ${EXTRA_RPMS}:"
ls "${EXTRA_RPMS}"/*.rpm 2>/dev/null || echo "  (none — check build errors above)"
echo ""
echo "Next: make VARIANT=bastion-core image"
