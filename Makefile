.DEFAULT_GOAL := repo
.PHONY: all deps rpm repo image publish-mirror smoke smoke-qcow2 run-vm stop-vm destroy-vm ssh-vm vm-status clean distclean help check check-versions check-versions-all check-settings check-size bless-size bless-boot-time diff-packages lint shellcheck validate sign verify bump-patch bump-minor bump-major install-hooks changelog sbom attest baseline-record smoke-rerun check-boot-time cve-scan brew-drift variants build-extra-rpms check-extra-rpms

# ── Variant dispatch ──────────────────────────────────────────────────────────
# `make` (no arg) defaults to the devbox variant. Override with VARIANT=<name>.
VARIANT       ?= devbox
FEDBUILD      := $(CURDIR)
VARIANT_DIR   := $(FEDBUILD)/variants/$(VARIANT)
VARIANT_TESTS := $(VARIANT_DIR)/tests

# Sanity: every variant must declare its own variant.mk.
ifeq ($(wildcard $(VARIANT_DIR)/variant.mk),)
$(error VARIANT='$(VARIANT)' is not defined — $(VARIANT_DIR)/variant.mk missing)
endif

# Pull in PKG_NAME, PKG_BLUEPRINT_NAME, PKG_IMAGE_FORMAT, EXTRA_REPOS.
include $(VARIANT_DIR)/variant.mk

# ── Variant-scoped paths ──────────────────────────────────────────────────────
TOPDIR              := $(FEDBUILD)/rpmbuild
REPODIR             := $(FEDBUILD)/repo/$(VARIANT)
OUTDIR              := $(FEDBUILD)/output/$(VARIANT)
SRCDIR              := $(VARIANT_DIR)/$(PKG_NAME)/SOURCES
SPECFILE            := $(VARIANT_DIR)/$(PKG_NAME)/SPECS/$(PKG_NAME).spec
BLUEPRINT           := $(VARIANT_DIR)/blueprint.toml
KEYFILE             := $(FEDBUILD)/keys/authorized_key
BLUEPRINT_EFFECTIVE := $(VARIANT_DIR)/blueprint.effective.toml
EXTRA_RPMS_DIR      := $(VARIANT_DIR)/extra-rpms
EXTRA_RPMS_FILES    := $(wildcard $(EXTRA_RPMS_DIR)/*.rpm)
EXTRA_RPMS_MANIFEST := $(EXTRA_RPMS_DIR)/EXPECTED_SHA256
SHA256SUMS_FILE     := $(OUTDIR)/SHA256SUMS
SHA256SUMS_SIG      := $(OUTDIR)/SHA256SUMS.sig
SHA256SUMS_CERT     := $(OUTDIR)/SHA256SUMS.pem
SIZE_FILE           := $(OUTDIR)/SIZE
SIZE_BASELINE       := $(VARIANT_TESTS)/size.baseline
SIZE_BUDGET_PCT     ?= 10
BOOT_TIME_BASELINE  := $(VARIANT_TESTS)/boot-time.baseline
BASELINES_CSV       := $(VARIANT_TESTS)/baselines.csv
CVE_ALLOWLIST       ?= $(VARIANT_TESTS)/cve-allowlist.yaml
SBOM                ?= $(OUTDIR)/sbom.cdx.json

PKG_VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' $(SPECFILE))
PKG_RELEASE := $(shell sed -n 's/^Release:[[:space:]]*\([^%]*\).*/\1/p' $(SPECFILE))
DIST        := $(shell rpm -E '%{?dist}')
ARCH        := noarch

RPM         := $(TOPDIR)/RPMS/$(ARCH)/$(PKG_NAME)-$(PKG_VERSION)-$(PKG_RELEASE)$(DIST).$(ARCH).rpm
REPO_MARKER := $(REPODIR)/repodata/repomd.xml
SOURCES     := $(wildcard $(SRCDIR)/*)

# ── Targets ───────────────────────────────────────────────────────────────────

all: repo

## deps: install createrepo_c (required by the repo target)
deps:
	rpm -q createrepo_c >/dev/null 2>&1 || sudo dnf install -y createrepo_c

## rpm: build $(PKG_NAME) RPM from spec + sources
## Reproducible: SOURCE_DATE_EPOCH pins buildtime + clamps mtimes; LC_ALL/TZ
## pinned for deterministic string formatting. Operator may pin SDE via env
## (overrides the git-log derivation) — required across renames + for external
## reproducers; see spec F5/F5a.
$(RPM): $(SPECFILE) $(SOURCES)
	mkdir -p $(TOPDIR)/{BUILD,RPMS,SRPMS,SPECS,SOURCES}
	@sde=$${SOURCE_DATE_EPOCH:-$$(git log -1 --format=%ct -- $(SPECFILE) $(SRCDIR) 2>/dev/null)}; \
	 sde=$${sde:-$$(date +%s)}; \
	 sha=$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
	 echo "VARIANT=$(VARIANT) SOURCE_DATE_EPOCH=$$sde GIT_COMMIT=$$sha"; \
	 env LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=$$sde rpmbuild \
		--define "_topdir    $(TOPDIR)"                 \
		--define "_sourcedir $(SRCDIR)"                 \
		--define "_buildhost reproducible.fedbuild"     \
		--define "_git_commit $$sha"                    \
		--define "clamp_mtime_to_source_date_epoch 1"   \
		--define "use_source_date_epoch_as_buildtime 1" \
		--define "source_date_epoch_from_changelog 0"   \
		-ba $(SPECFILE)
	@touch $@

rpm: $(RPM)

## repo: copy fedbuild RPM (+ optional $(EXTRA_RPMS_DIR)/*.rpm) into local yum repo
## extra-rpms supply chain (F7a): if EXPECTED_SHA256 manifest is present,
## verify each upstream RPM matches before folding it in. Otherwise warn but
## continue (operator accepts responsibility per variant README).
$(REPO_MARKER): $(RPM) $(EXTRA_RPMS_FILES)
	@command -v createrepo >/dev/null 2>&1 || \
		{ echo "createrepo_c not found — run: make deps"; exit 1; }
	rm -rf $(REPODIR)
	mkdir -p $(REPODIR)
	cp -v $(RPM) $(REPODIR)/
	@if [ -d $(EXTRA_RPMS_DIR) ] && [ -n "$$(find $(EXTRA_RPMS_DIR) -maxdepth 1 -name '*.rpm' -print -quit)" ]; then \
	   if [ -f $(EXTRA_RPMS_MANIFEST) ] && [ -s $(EXTRA_RPMS_MANIFEST) ]; then \
	     echo "Verifying extra-rpms against $(EXTRA_RPMS_MANIFEST)..."; \
	     (cd $(EXTRA_RPMS_DIR) && sha256sum -c EXPECTED_SHA256) || \
	         { echo "ERROR: extra-rpms checksum mismatch — refusing to build"; exit 1; }; \
	   else \
	     echo "WARN: $(EXTRA_RPMS_DIR) has RPMs but no EXPECTED_SHA256 manifest — see variant README for supply-chain posture"; \
	   fi; \
	   find $(EXTRA_RPMS_DIR) -maxdepth 1 -name '*.rpm' -exec cp -v {} $(REPODIR)/ \; ; \
	 fi
	createrepo $(REPODIR)

repo: $(REPO_MARKER)

## blueprint.effective.toml: substitute local SSH key into blueprint (requires keys/authorized_key)
$(BLUEPRINT_EFFECTIVE): $(BLUEPRINT) $(KEYFILE)
	@test -f $(KEYFILE) || { echo "ERROR: keys/authorized_key not found"; exit 1; }
	sed "s|ssh-ed25519 CHANGEME user@localhost|$$(cat $(KEYFILE))|" $(BLUEPRINT) > $(BLUEPRINT_EFFECTIVE)

## image: build the variant's VM image (osbuild requires sudo for mount)
## Produces both raw.zst (field-deploy; dd to media) and qcow2 (ADCON runtime;
## consumed by bastion-qemu). qcow2 is derived from the raw.zst via qemu-img
## convert so both formats descend from one reproducible image-builder output.
image: check-extra-rpms $(REPO_MARKER) $(BLUEPRINT_EFFECTIVE)
	@pid_file=$(OUTDIR)/run/qemu.pid; \
	 if [ -f "$$pid_file" ] && kill -0 "$$(cat $$pid_file)" 2>/dev/null; then \
	     echo "ERROR: $(VARIANT) VM is running (PID $$(cat $$pid_file)) — run: make VARIANT=$(VARIANT) stop-vm"; exit 1; \
	 fi
	mkdir -p $(OUTDIR)
	sudo image-builder build              \
		--distro     fedora-43            \
		--blueprint  $(BLUEPRINT_EFFECTIVE) \
		--extra-repo file://$(REPODIR)    \
		$(EXTRA_REPOS)                    \
		--output-dir $(OUTDIR)            \
		$(PKG_IMAGE_FORMAT)
	$(if $(IMAGE_TRIM),sudo bash $(IMAGE_TRIM) "$$(find $(OUTDIR) -name '*.raw.zst' | sort | tail -1)" $(BLUEPRINT) fedora-43 $(PKG_IMAGE_FORMAT))
	cp -v $(RPM) $(OUTDIR)/
	@command -v zstd >/dev/null 2>&1 || { echo "ERROR: zstd not found — required for qcow2 derivation"; exit 1; }
	@command -v qemu-img >/dev/null 2>&1 || { echo "ERROR: qemu-img not found — install qemu-utils / qemu-img"; exit 1; }
	@img=$$(find $(OUTDIR) -name '*.raw.zst' | sort | tail -1); \
	 test -n "$$img" || { echo "ERROR: no *.raw.zst in $(OUTDIR) — image-builder output missing"; exit 1; }; \
	 qcow=$$(echo "$$img" | sed 's/\.raw\.zst$$/.qcow2/'); \
	 tmpraw=$$(mktemp --tmpdir=$(OUTDIR) raw-XXXXXX.raw); \
	 echo "Decompressing $$(basename "$$img") → $$(basename "$$tmpraw")"; \
	 zstd -df --quiet "$$img" -o "$$tmpraw"; \
	 echo "Converting   $$(basename "$$tmpraw") → $$(basename "$$qcow") (qcow2, sparse)"; \
	 qemu-img convert -f raw -O qcow2 "$$tmpraw" "$$qcow"; \
	 rm -f "$$tmpraw"; \
	 echo "Wrote $$qcow ($$(stat -c%s "$$qcow") bytes)"
	cd $(OUTDIR) && sha256sum $$(find . -maxdepth 1 \( -name '*.raw.zst' -o -name '*.qcow2' \) -printf '%P\n') > SHA256SUMS
	@cd $(OUTDIR) && for f in $$(basename $(RPM)) sbom.cdx.json sbom.spdx.json provenance.json; do \
	     [ -f "$$f" ] && sha256sum "$$f" >> SHA256SUMS && echo "  + $$f"; \
	 done; true
	@echo "Wrote $(OUTDIR)/SHA256SUMS"
	@img=$$(find $(OUTDIR) -name '*.raw.zst' | sort | tail -1); \
	 stat -c%s "$$img" > $(SIZE_FILE); \
	 echo "Wrote $(SIZE_FILE) ($$(cat $(SIZE_FILE)) bytes — raw.zst basis)"
	@$(MAKE) --no-print-directory check-size

## build-extra-rpms: rebuild all extra-rpms for this variant from source repos (then re-run make image)
## Passes BASTION_RPM_VERSION=$(PKG_VERSION) so all built RPMs match the variant's declared version.
build-extra-rpms:
	@test -f $(VARIANT_DIR)/scripts/build-extra-rpms.sh || \
	    { echo "ERROR: $(VARIANT_DIR)/scripts/build-extra-rpms.sh not found — variant has no extra-rpms build script"; exit 1; }
	BASTION_RPM_VERSION=$(PKG_VERSION) bash $(VARIANT_DIR)/scripts/build-extra-rpms.sh

## check-extra-rpms: gate — fail if an extra-rpm is older than its source repo's HEAD,
## or its spec builds a package the directory lacks. Rebuild from the source repo, then retry.
check-extra-rpms:
	@bash $(FEDBUILD)/scripts/check-extra-rpms.sh $(EXTRA_RPMS_DIR) $(FEDBUILD)/..

## check: fast pre-push checks — shellcheck, TOML syntax, actionlint, settings schema (no RPM build)
check: check-versions check-settings shellcheck
	@yq -p toml -oy '.' $(BLUEPRINT) >/dev/null && echo "$(VARIANT) blueprint.toml: OK"
	actionlint $(FEDBUILD)/.github/workflows/ci.yml

## check-settings: JSON-schema validate baked agent-settings.json (devbox only — others may opt-in)
check-settings:
	@settings=$(SRCDIR)/agent-settings.json; \
	 if [ -f $$settings ] && [ -f $(FEDBUILD)/schemas/agent-settings.schema.json ]; then \
	   command -v check-jsonschema >/dev/null 2>&1 || \
	     { echo "ERROR: check-jsonschema not found — pip install check-jsonschema"; exit 1; }; \
	   check-jsonschema --schemafile $(FEDBUILD)/schemas/agent-settings.schema.json $$settings; \
	 else \
	   echo "check-settings: no agent-settings.json for VARIANT=$(VARIANT) — skipping"; \
	 fi

## check-size: fail if built image exceeds baseline * (1 + SIZE_BUDGET_PCT/100)
check-size:
	@test -f $(SIZE_FILE) || { echo "ERROR: $(SIZE_FILE) missing — run: make image"; exit 1; }
	@test -f $(SIZE_BASELINE) || { echo "ERROR: $(SIZE_BASELINE) missing — run: make bless-size"; exit 1; }
	@cur=$$(cat $(SIZE_FILE)); base=$$(cat $(SIZE_BASELINE)); pct=$(SIZE_BUDGET_PCT); \
	 limit=$$(( base + base * pct / 100 )); \
	 delta=$$(( cur - base )); \
	 pct_delta=$$(awk -v c=$$cur -v b=$$base 'BEGIN{printf "%.2f", (c-b)*100.0/b}'); \
	 echo "Image size: $$cur bytes (baseline $$base, $$pct_delta%, budget +$$pct%)"; \
	 if [ "$$cur" -gt "$$limit" ]; then \
	     echo "ERROR: image exceeds baseline by >$$pct% (cur=$$cur, limit=$$limit, delta=$$delta)"; exit 1; \
	 fi

## bless-size: promote current image size to baseline (commit $(SIZE_BASELINE))
bless-size:
	@test -f $(SIZE_FILE) || { echo "ERROR: $(SIZE_FILE) missing — run: make image"; exit 1; }
	cp $(SIZE_FILE) $(SIZE_BASELINE)
	@echo "Baseline updated → $(SIZE_BASELINE) ($$(cat $(SIZE_BASELINE)) bytes)"

## bless-boot-time: promote FIRSTBOOT_SECS to $(BOOT_TIME_BASELINE)
## Usage: FIRSTBOOT_SECS=<observed> make bless-boot-time
bless-boot-time:
	@test -n "$(FIRSTBOOT_SECS)" || { echo "ERROR: set FIRSTBOOT_SECS=<seconds> (observed from last successful: make smoke)"; exit 1; }
	@echo "$(FIRSTBOOT_SECS)" > $(BOOT_TIME_BASELINE)
	@echo "Boot-time baseline updated → $(BOOT_TIME_BASELINE) ($(FIRSTBOOT_SECS)s)"

## check-versions: assert RPM spec Version and blueprint version match (this variant)
check-versions:
	@spec_ver=$$(sed -n 's/^Version:[[:space:]]*//p' $(SPECFILE)); \
	 bp_ver=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 if [ "$$spec_ver" != "$$bp_ver" ]; then \
	     echo "ERROR: $(VARIANT) version mismatch — spec=$$spec_ver blueprint=$$bp_ver"; exit 1; \
	 else \
	     echo "$(VARIANT) versions match: $$spec_ver"; \
	 fi

## check-versions-all: run check-versions for every discovered variant
check-versions-all:
	@for v in $$(ls $(FEDBUILD)/variants 2>/dev/null); do \
	   $(MAKE) --no-print-directory VARIANT=$$v check-versions || exit 1; \
	 done

## variants: list known variants with their description (first non-blank line of variant README)
variants:
	@for d in $(FEDBUILD)/variants/*/; do \
	   v=$$(basename $$d); \
	   desc=$$(awk 'NR==1 && /^# / { sub(/^# /,""); print; exit } /^[A-Za-z]/ { print; exit }' $$d/README.md 2>/dev/null || echo "(no README)"); \
	   printf "  %-20s %s\n" "$$v" "$$desc"; \
	 done

## shellcheck: lint shell scripts in this variant + repo-root scripts
shellcheck:
	@scripts=""; \
	 for s in $(FEDBUILD)/../vm.sh $(FEDBUILD)/scripts/avc-denials.sh $(FEDBUILD)/scripts/check-extra-rpms.sh $(SRCDIR)/firstboot.sh $(SRCDIR)/devbox-profile.sh $(VARIANT_TESTS)/smoke.sh $(VARIANT_TESTS)/smoke-rerun.sh $(VARIANT_TESTS)/diff-packages.sh $(VARIANT_TESTS)/brew-drift.sh $(IMAGE_TRIM); do \
	   [ -f $$s ] && scripts="$$scripts $$s"; \
	 done; \
	 if [ -n "$$scripts" ]; then shellcheck $$scripts; else echo "shellcheck: no scripts to check for VARIANT=$(VARIANT)"; fi

## lint: run shellcheck and rpmlint against the spec when available
lint: shellcheck
	@if command -v rpmlint >/dev/null 2>&1; then \
		rpmlint --config $(FEDBUILD)/.rpmlintrc --ignore-unused-rpmlintrc $(SPECFILE); \
	else \
		echo "rpmlint not found; checked shell scripts only"; \
	fi

## validate: check blueprint syntax, SSH key, and target image type
validate: $(BLUEPRINT_EFFECTIVE)
	@echo "Checking TOML syntax..."
	@yq -p toml -oy '.' $(BLUEPRINT_EFFECTIVE) >/dev/null && echo "  OK"
	@echo "Checking SSH key placeholder..."
	@! grep -q 'CHANGEME' $(BLUEPRINT_EFFECTIVE) && echo "  OK" || \
		{ echo "  ERROR: SSH key not substituted in blueprint.effective.toml"; exit 1; }
	@echo "Checking target image type..."
	@image-builder list 2>/dev/null | grep -q "fedora-43.*$(PKG_IMAGE_FORMAT).*x86_64" && echo "  OK" || \
		{ echo "  ERROR: fedora-43 $(PKG_IMAGE_FORMAT) x86_64 not found in image-builder list"; exit 1; }

## sign: cosign keyless-sign $(SHA256SUMS_FILE) (Sigstore OIDC); writes .sig + .pem
sign:
	@command -v cosign >/dev/null 2>&1 || \
		{ echo "ERROR: cosign not found — https://github.com/sigstore/cosign"; exit 1; }
	@test -f $(SHA256SUMS_FILE) || \
		{ echo "ERROR: $(SHA256SUMS_FILE) not found — run: make image"; exit 1; }
	cosign sign-blob --yes \
		--output-signature  $(SHA256SUMS_SIG)  \
		--output-certificate $(SHA256SUMS_CERT) \
		$(SHA256SUMS_FILE)
	@echo "Signed $(SHA256SUMS_FILE) → $(SHA256SUMS_SIG) + $(SHA256SUMS_CERT)"

## verify: cosign verify SHA256SUMS against Rekor (CERT_IDENTITY + CERT_OIDC_ISSUER required)
verify:
	@command -v cosign >/dev/null 2>&1 || { echo "ERROR: cosign not found"; exit 1; }
	@test -f $(SHA256SUMS_FILE) || { echo "ERROR: $(SHA256SUMS_FILE) not found"; exit 1; }
	@test -f $(SHA256SUMS_SIG)  || { echo "ERROR: $(SHA256SUMS_SIG) not found — run: make sign"; exit 1; }
	@test -f $(SHA256SUMS_CERT) || { echo "ERROR: $(SHA256SUMS_CERT) not found — run: make sign"; exit 1; }
	@test -n "$(CERT_IDENTITY)"    || { echo "ERROR: set CERT_IDENTITY=<email|URI>"; exit 1; }
	@test -n "$(CERT_OIDC_ISSUER)" || { echo "ERROR: set CERT_OIDC_ISSUER=<issuer URL>"; exit 1; }
	cosign verify-blob \
		--certificate           $(SHA256SUMS_CERT)  \
		--signature             $(SHA256SUMS_SIG)   \
		--certificate-identity  $(CERT_IDENTITY)    \
		--certificate-oidc-issuer $(CERT_OIDC_ISSUER) \
		$(SHA256SUMS_FILE)

## sbom: generate CycloneDX + SPDX SBOMs from built image (requires syft)
sbom:
	@command -v syft >/dev/null 2>&1 || \
		{ echo "ERROR: syft not found — https://github.com/anchore/syft"; exit 1; }
	@img=$$(find $(OUTDIR) -name '*.raw.zst' | sort | tail -1); \
	 test -n "$$img" || { echo "ERROR: no *.raw.zst in $(OUTDIR) — run: make image"; exit 1; }; \
	 echo "Generating CycloneDX SBOM: $$img → $(OUTDIR)/sbom.cdx.json"; \
	 syft "$$img" -o cyclonedx-json=$(OUTDIR)/sbom.cdx.json; \
	 echo "Generating SPDX SBOM: $$img → $(OUTDIR)/sbom.spdx.json"; \
	 syft "$$img" -o spdx-json=$(OUTDIR)/sbom.spdx.json; \
	 echo "SBOMs written to $(OUTDIR)/"

## attest: emit SLSA v1 provenance JSON + cosign keyless attest-blob (Sigstore OIDC)
attest:
	@command -v cosign >/dev/null 2>&1 || \
		{ echo "ERROR: cosign not found — https://github.com/sigstore/cosign"; exit 1; }
	@img=$$(find $(OUTDIR) -name '*.raw.zst' | sort | tail -1); \
	 test -n "$$img" || { echo "ERROR: no *.raw.zst in $(OUTDIR) — run: make image"; exit 1; }; \
	 img_digest=$$(sha256sum "$$img" | awk '{print $$1}'); \
	 git_commit=$$(git rev-parse HEAD 2>/dev/null || echo "unknown"); \
	 build_ts=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
	 printf '{\n  "buildType": "https://fedbuild.rethunk.tech/make-image/v1",\n  "builder": {"id": "make image VARIANT=$(VARIANT)"},\n  "invocation": {"configSource": {"uri": "git+https://github.com/Rethunk-Tech/fedbuild", "digest": {"sha1": "%s"}}},\n  "materials": [{"uri": "git+https://github.com/Rethunk-Tech/fedbuild", "digest": {"sha1": "%s"}}, {"uri": "%s", "digest": {"sha256": "%s"}}],\n  "metadata": {"buildStartedOn": "%s", "variant": "$(VARIANT)"}\n}\n' \
	     "$$git_commit" "$$git_commit" "$$(basename $$img)" "$$img_digest" "$$build_ts" \
	     > $(OUTDIR)/provenance.json; \
	 echo "Wrote $(OUTDIR)/provenance.json"; \
	 cosign attest-blob --yes \
	     --type slsaprovenance1 \
	     --predicate $(OUTDIR)/provenance.json \
	     --output-signature $(OUTDIR)/provenance.sig \
	     --output-certificate $(OUTDIR)/provenance.pem \
	     "$$img"; \
	 echo "Signed $(OUTDIR)/provenance.json → $(OUTDIR)/provenance.sig + $(OUTDIR)/provenance.pem"

## cve-scan: scan SBOM with grype; fail on critical CVEs not in $(CVE_ALLOWLIST)
cve-scan:
	@command -v grype >/dev/null 2>&1 || \
		{ echo "ERROR: grype not found — brew install grype"; exit 1; }
	@test -f $(SBOM) || { echo "ERROR: $(SBOM) not found — run: make sbom"; exit 1; }
	@test -f $(CVE_ALLOWLIST) || { echo "ERROR: $(CVE_ALLOWLIST) not found"; exit 1; }
	grype sbom:$(SBOM) -c $(CVE_ALLOWLIST)

## brew-drift: diff two brew-versions.txt snapshots → added/removed/bumped
## Usage: OLD=path/to/old/brew-versions.txt NEW=path/to/new/brew-versions.txt make brew-drift
brew-drift:
	@test -n "$(OLD)" || { echo "ERROR: set OLD=<path to older brew-versions.txt>"; exit 1; }
	@test -n "$(NEW)" || { echo "ERROR: set NEW=<path to newer brew-versions.txt>"; exit 1; }
	@bash $(VARIANT_TESTS)/brew-drift.sh "$(OLD)" "$(NEW)"

## diff-packages: compare blueprint-declared RPMs against rpm -qa on a running VM
## (override: VM_HOST=user@localhost VM_SSH_PORT=2222 SSH_KEY=keys/authorized_key)
diff-packages:
	@BLUEPRINT="$(BLUEPRINT)" bash $(VARIANT_TESTS)/diff-packages.sh

## smoke: boot VM in QEMU/KVM and verify firstboot (requires built image + KVM)
## SSH_KEY must point to the private key matching keys/authorized_key.
## SSH_PORT is each smoke.sh's default (devbox 2222, bastion-core/edge 2223) unless set.
smoke:
	@test -d $(OUTDIR) || { echo "ERROR: $(OUTDIR) not found — run: make image first"; exit 1; }
	@command -v qemu-system-x86_64 >/dev/null 2>&1 || \
		{ echo "ERROR: qemu-system-x86_64 not found — install qemu-kvm"; exit 1; }
	bash $(VARIANT_TESTS)/smoke.sh $(OUTDIR)

## smoke-qcow2: alias for smoke — bastion-core smoke.sh always uses qcow2.
smoke-qcow2: smoke

## run-vm: launch the umbrella-root VM manager for $(VM_VARIANT)
## Fresh by default (new run/ state + new bastion-core bootstrap identity). Set VM_REUSE_STATE=1 to resume.
## Runtime default is bastion-core; override with VM_VARIANT=<name> for other images.
VM_VARIANT ?= bastion-core
VM_OUTDIR  ?= $(FEDBUILD)/output/$(VM_VARIANT)
VM_SSH_PORT ?= $(if $(filter $(VM_VARIANT),bastion-core),2224,$(if $(filter $(VM_VARIANT),bastion-edge),2232,2222))
VM_WEB_PORT ?= $(if $(filter $(VM_VARIANT),bastion-core),4173,)
VM_WS_PORT  ?= $(if $(filter $(VM_VARIANT),bastion-core),8765,)
VM_SCRIPT   := $(FEDBUILD)/../vm.sh
define require-vm-script
@test -f $(VM_SCRIPT) || { \
  echo "ERROR: $(VM_SCRIPT) not found — vm.sh is the Bastion meta-repo launcher (parent of this clone)."; \
  echo "Standalone Rethunk-Tech/fedbuild: make image && make smoke. Nested under Bastion: ../vm.sh up"; \
  exit 1; }
endef
run-vm:
	$(require-vm-script)
	@VARIANT="$(VM_VARIANT)" \
	OUTDIR="$(VM_OUTDIR)" \
	VM_SSH_PORT="$(VM_SSH_PORT)" \
	VM_WEB_PORT="$(VM_WEB_PORT)" \
	VM_WS_PORT="$(VM_WS_PORT)" \
	VM_SSH_KEY="$(VM_SSH_KEY)" \
	VM_REUSE_STATE="$(VM_REUSE_STATE)" \
	VM_BUILD_IF_MISSING="$(VM_BUILD_IF_MISSING)" \
	TIMEOUT_SSH="$(TIMEOUT_SSH)" \
	TIMEOUT_FIRSTBOOT="$(TIMEOUT_FIRSTBOOT)" \
	SERIAL_TAIL="$(SERIAL_TAIL)" \
	bash $(VM_SCRIPT) up

## stop-vm: gracefully stop $(VM_VARIANT) through the umbrella-root VM manager
stop-vm:
	$(require-vm-script)
	@VARIANT="$(VM_VARIANT)" OUTDIR="$(VM_OUTDIR)" bash $(VM_SCRIPT) down

## destroy-vm: stop $(VM_VARIANT) and delete output/<variant>/run through the umbrella-root VM manager
destroy-vm:
	$(require-vm-script)
	@VARIANT="$(VM_VARIANT)" OUTDIR="$(VM_OUTDIR)" bash $(VM_SCRIPT) destroy

## ssh-vm: open an SSH session to the running $(VM_VARIANT) VM through the umbrella-root VM manager
ssh-vm:
	$(require-vm-script)
	@VARIANT="$(VM_VARIANT)" \
	OUTDIR="$(VM_OUTDIR)" \
	VM_SSH_PORT="$(VM_SSH_PORT)" \
	VM_SSH_KEY="$(VM_SSH_KEY)" \
	bash $(VM_SCRIPT) ssh

## stage-tm-image: copy bastion-edge qcow2 into the running bastion-core VM for TheatreManager provisioning
## Requires: make VARIANT=bastion-edge image && make run-vm
stage-tm-image:
	@KEY=$(VM_OUTDIR)/run/ssh-key; \
	 test -f "$$KEY" || { echo "ERROR: run: make run-vm first"; exit 1; }; \
	 SRC=$(CURDIR)/output/bastion-edge/fedora-43-minimal-raw-zst-x86_64.qcow2; \
	 test -f "$$SRC" || { echo "ERROR: build bastion-edge first: make VARIANT=bastion-edge image"; exit 1; }; \
	 echo "[stage-tm-image] Copying bastion-edge qcow2 to VM (may take a few minutes for 2.5 GB)..."; \
	 scp -P $(VM_SSH_PORT) -i "$$KEY" \
	     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	     "$$SRC" bastion-operator@localhost:/var/lib/bastion/qemu/images/bastion-edge.qcow2; \
	 ssh -p $(VM_SSH_PORT) -i "$$KEY" \
	     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	     bastion-operator@localhost \
	     "chgrp bastion-qemu /var/lib/bastion/qemu/images/bastion-edge.qcow2 && \
	      chmod 0640 /var/lib/bastion/qemu/images/bastion-edge.qcow2"; \
	 echo "[stage-tm-image] Done — bastion-edge image staged"

## vm-status: show running state of $(VM_VARIANT) through the umbrella-root VM manager
vm-status:
	$(require-vm-script)
	@VARIANT="$(VM_VARIANT)" \
	OUTDIR="$(VM_OUTDIR)" \
	VM_SSH_PORT="$(VM_SSH_PORT)" \
	VM_WEB_PORT="$(VM_WEB_PORT)" \
	VM_WS_PORT="$(VM_WS_PORT)" \
	VM_SSH_KEY="$(VM_SSH_KEY)" \
	bash $(VM_SCRIPT) status

## baseline-record: append a row to $(BASELINES_CSV) from env vars
## Usage: BUILD_SECS=30 IMAGE_BYTES=1234567890 FIRSTBOOT_SECS=900 SECONDBOOT_SECS=5 make baseline-record
baseline-record:
	@printf '%s,%s,%s,%s,%s,%s\n' \
	     "$$(git rev-parse HEAD 2>/dev/null || echo '')" \
	     "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	     "$${BUILD_SECS:-}" \
	     "$${IMAGE_BYTES:-}" \
	     "$${FIRSTBOOT_SECS:-}" \
	     "$${SECONDBOOT_SECS:-}" \
	     >> $(BASELINES_CSV)
	@echo "Appended row to $(BASELINES_CSV)"

## smoke-rerun: re-run smoke test against an existing image (idempotency check)
smoke-rerun:
	@test -f $(VARIANT_TESTS)/smoke-rerun.sh || \
		{ echo "ERROR: $(VARIANT_TESTS)/smoke-rerun.sh not found"; exit 1; }
	bash $(VARIANT_TESTS)/smoke-rerun.sh $(OUTDIR)

## check-boot-time: fail if latest firstboot_secs > median of last 5 entries * 1.2
## CSV header: commit,date,build_secs,image_bytes,firstboot_secs,secondboot_secs
BOOT_TIME_N ?= 5
check-boot-time:
	@test -f $(BASELINES_CSV) || { echo "ERROR: $(BASELINES_CSV) not found — run: make baseline-record"; exit 1; }
	@awk -F, -v want_n=$(BOOT_TIME_N) ' \
	     NR==1 { \
	         for (i=1; i<=NF; i++) if ($$i=="firstboot_secs") col=i; \
	         if (!col) { print "ERROR: baselines.csv has no firstboot_secs column"; exit 1; } \
	         next; \
	     } \
	     $$col!="" { rows[++n]=$$col } \
	     END { \
	     if (n < 3) { print "INFO: fewer than 3 firstboot_secs entries (" n+0 ") — skipping boot-time check"; exit 0; } \
	     window = (n < want_n) ? n : want_n; \
	     start = n - window + 1; \
	     for (i=start; i<=n; i++) vals[i-start+1]=rows[i]; \
	     asort(vals, sorted); \
	     mid = int((window+1)/2); \
	     median = (window%2==1) ? sorted[mid] : (sorted[mid]+sorted[mid+1])/2.0; \
	     latest = rows[n]; \
	     limit = median * 1.2; \
	     printf "Latest firstboot_secs: %s  median(%d): %.1f  limit: %.1f\n", latest, window, median, limit; \
	     if (latest+0 > limit) { \
	         printf "ERROR: firstboot_secs %s exceeds median*1.2 (%.1f)\n", latest, limit; exit 1; \
	     } else { print "OK: within budget"; } \
	 }' $(BASELINES_CSV)

## publish-mirror: stage built qcow2 + sha256 + SBOM + provenance into the ADCON
## authoritative-mirror layout. Target directory tree matches the route parser
## in bastion-core/apps/server/src/adcon/deployment/adcon-mirror-routes.ts:
##   $(MIRROR_DIR)/vm-images/$(VARIANT)/$(PKG_VERSION)/<filename>
## MIRROR_DIR defaults to $(OUTDIR)/mirror-stage for local smoke; operators set
## MIRROR_DIR=/var/lib/bastion/adcon-mirror for production publish.
MIRROR_DIR ?= $(OUTDIR)/mirror-stage
publish-mirror:
	@test -d $(OUTDIR) || { echo "ERROR: $(OUTDIR) not found — run: make image"; exit 1; }
	@qcow=$$(find $(OUTDIR) -maxdepth 1 -name '*.qcow2' | sort | tail -1); \
	 test -n "$$qcow" || { echo "ERROR: no *.qcow2 in $(OUTDIR) — run: make image"; exit 1; }; \
	 dst=$(MIRROR_DIR)/vm-images/$(VARIANT)/$(PKG_VERSION); \
	 mkdir -p "$$dst"; \
	 cp -v "$$qcow" "$$dst/"; \
	 (cd $(OUTDIR) && grep " $$(basename $$qcow)$$" SHA256SUMS) > "$$dst/$$(basename $$qcow).sha256"; \
	 for f in sbom.cdx.json sbom.spdx.json provenance.json provenance.sig provenance.pem SHA256SUMS SHA256SUMS.sig SHA256SUMS.pem; do \
	   [ -f $(OUTDIR)/$$f ] && cp -v $(OUTDIR)/$$f "$$dst/" || true; \
	 done; \
	 echo "Published $(VARIANT) $(PKG_VERSION) → $$dst"

## clean: remove rpmbuild tree, this variant's local repo, and effective blueprint
clean:
	rm -rf $(TOPDIR) $(REPODIR) $(BLUEPRINT_EFFECTIVE)

## distclean: clean + remove this variant's built images
distclean: clean
	rm -rf $(OUTDIR)

## bump-patch: bump Z in X.Y.Z (spec Release=1, blueprint version lockstep) — this variant only
bump-patch:
	@cur=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 X=$$(echo "$$cur" | cut -d. -f1); \
	 Y=$$(echo "$$cur" | cut -d. -f2); \
	 Z=$$(echo "$$cur" | cut -d. -f3); \
	 new="$$X.$$Y.$$((Z+1))"; \
	 sed -i "s/^Version:[[:space:]].*/Version:        $$new/" $(SPECFILE); \
	 sed -i "s/^version[[:space:]]*=.*/version = \"$$new\"/" $(BLUEPRINT); \
	 echo "Bumped $(VARIANT) $$cur → $$new"; \
	 $(MAKE) --no-print-directory check-versions

## bump-minor: bump Y in X.Y.Z (resets Z to 0)
bump-minor:
	@cur=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 X=$$(echo "$$cur" | cut -d. -f1); \
	 Y=$$(echo "$$cur" | cut -d. -f2); \
	 new="$$X.$$((Y+1)).0"; \
	 sed -i "s/^Version:[[:space:]].*/Version:        $$new/" $(SPECFILE); \
	 sed -i "s/^version[[:space:]]*=.*/version = \"$$new\"/" $(BLUEPRINT); \
	 echo "Bumped $(VARIANT) $$cur → $$new"; \
	 $(MAKE) --no-print-directory check-versions

## bump-major: bump X in X.Y.Z (resets Y.Z to 0.0)
bump-major:
	@cur=$$(yq -p toml -oy '.version' $(BLUEPRINT)); \
	 X=$$(echo "$$cur" | cut -d. -f1); \
	 new="$$((X+1)).0.0"; \
	 sed -i "s/^Version:[[:space:]].*/Version:        $$new/" $(SPECFILE); \
	 sed -i "s/^version[[:space:]]*=.*/version = \"$$new\"/" $(BLUEPRINT); \
	 echo "Bumped $(VARIANT) $$cur → $$new"; \
	 $(MAKE) --no-print-directory check-versions

## changelog: regenerate CHANGELOG.md from Conventional Commits (via git-cliff + cliff.toml)
changelog:
	@command -v git-cliff >/dev/null 2>&1 || \
		{ echo "ERROR: git-cliff not found — brew install git-cliff"; exit 1; }
	git-cliff --config $(FEDBUILD)/cliff.toml --output $(FEDBUILD)/CHANGELOG.md
	@echo "Regenerated CHANGELOG.md"

## install-hooks: install the git hooks defined in lefthook.yml
install-hooks:
	@command -v lefthook >/dev/null 2>&1 || \
		{ echo "ERROR: lefthook not found — uv tool install lefthook"; exit 1; }
	lefthook install
	@echo "Installed → .git/hooks/pre-commit"

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
