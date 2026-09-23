# variants/bastion-edge/variant.mk — per-variant Makefile overrides for VARIANT=bastion-edge.
# Included from root Makefile via `-include $(VARIANT_DIR)/variant.mk`.

PKG_NAME           := bastion-edge-firstboot
PKG_BLUEPRINT_NAME := fedora-43-bastion-edge
PKG_IMAGE_FORMAT   := minimal-raw-zst

# Edge variant pulls only from upstream Fedora repos + the local fedbuild repo
# (which includes extra-rpms/bastion-edge-*.rpm operator-supplied at build time).
# No third-party RPM repos by design — minimal attack surface.
EXTRA_REPOS        :=

# Post-build removal of the installer, wifi and all-langpacks closures.
IMAGE_TRIM         := $(VARIANT_DIR)/trim-image.sh
