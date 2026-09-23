# variants/bastion-core/variant.mk — per-variant Makefile overrides for VARIANT=bastion-core.
# Included from root Makefile via `-include $(VARIANT_DIR)/variant.mk`.

PKG_NAME           := bastion-core-firstboot
PKG_BLUEPRINT_NAME := fedora-44-bastion-core
PKG_IMAGE_FORMAT   := minimal-raw-zst

# bastion-core pulls from upstream Fedora repos + the local fedbuild repo
# (which includes extra-rpms/ operator-supplied at build time).
# No third-party RPM repos by design.
EXTRA_REPOS        :=
