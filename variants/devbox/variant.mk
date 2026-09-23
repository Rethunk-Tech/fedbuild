# variants/devbox/variant.mk — per-variant Makefile overrides for VARIANT=devbox.
# Included from root Makefile via `-include $(VARIANT_DIR)/variant.mk`.

PKG_NAME           := bastion-vm-firstboot
PKG_BLUEPRINT_NAME := fedora-44-devbox
PKG_IMAGE_FORMAT   := minimal-raw-zst

# Extra repos image-builder should pull from when materialising this variant.
# The local fedbuild repo (built by `make repo`) is passed separately by the
# root Makefile's `image` target; this variable covers third-party sources.
EXTRA_REPOS        := --extra-repo https://packages.microsoft.com/yumrepos/vscode \
                      --extra-repo https://pkg.cloudflare.com/cloudflared/rpm
