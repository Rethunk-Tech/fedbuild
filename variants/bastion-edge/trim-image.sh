#!/usr/bin/env bash
# variants/bastion-edge/trim-image.sh — remove the installer, wifi and
# all-langpacks closures from a built minimal-raw image, in place.
#
# Usage (root): trim-image.sh IMAGE.raw.zst BLUEPRINT.toml DISTRO IMAGE_TYPE
#
# minimal-raw always installs initial-setup (and through it anaconda) plus wifi
# support, and a blueprint can only add packages, so they come out afterwards
# with an offline `dnf5 --installroot remove`.
set -euo pipefail

IMAGE=$1
BLUEPRINT=$2
DISTRO=$3
IMAGE_TYPE=$4

# The roots only; dnf removes whatever they alone pulled in.
REMOVE=(initial-setup glibc-all-langpacks NetworkManager-wifi wpa_supplicant iw 'iwlwifi-*' wireless-regdb)

work=$(mktemp -d --tmpdir="$(dirname "$IMAGE")" trim-XXXXXX)
raw=$work/disk.raw
root=$work/root
loop=""
cleanup() {
    mountpoint -q "$root" 2>/dev/null && umount "$root"
    [[ -n "$loop" ]] && losetup -d "$loop"
    rm -rf "$work"
}
trap cleanup EXIT

zstd -dq "$IMAGE" -o "$raw"
loop=$(losetup -P --show -f "$raw")
rootdev=$(blkid -o device -t LABEL=root "$loop"p*)
mkdir "$root"
mount "$rootdev" "$root"

# The removal only has to touch the root filesystem: no removed package ships
# files under /boot, and anything that did would land in the unmounted /boot
# directory, which the check below refuses.
dnf=(dnf5 -y -q --installroot="$root" --disablerepo='*' --setopt=cachedir="$work/cache")

# Everything the blueprint or the image type asks for by name, plus packages
# the image gets only through @core or anaconda's requirements that the device
# still needs: NetworkManager (@core, but NetworkManager-wifi requires it),
# parted (@core, required by anaconda), chrony (anaconda's; mTLS needs a
# synced clock).
mapfile -t keep < <(
    {
        yq -p toml -oy '.packages[].name' "$BLUEPRINT"
        image-builder describe --distro "$DISTRO" "$IMAGE_TYPE" | grep -v '^@WARNING' |
            yq '.packages.os.include[]' | grep -v '^@'
        printf '%s\n' NetworkManager parted chrony
    } | grep -vxF -f <(printf '%s\n' "${REMOVE[@]}") | grep -v '^iwlwifi-' | sort -u
)

# osbuild installs with rpm, which records no install reason, so dnf treats
# every package as user-installed and would remove nothing beyond the roots.
"${dnf[@]}" mark dependency '*'
"${dnf[@]}" mark user "${keep[@]}"
"${dnf[@]}" remove "${REMOVE[@]}"

missing=$(rpm --root "$root" -q "${keep[@]}" | grep 'is not installed' || true)
[[ -z "$missing" ]] || {
    echo "trim-image: removal took required packages:" >&2
    echo "$missing" >&2
    exit 1
}
if [[ -n "$(ls -A "$root/boot")" ]]; then
    echo "trim-image: removal wrote under the unmounted /boot" >&2
    exit 1
fi

rm -rf "$root/var/log/dnf5.log"*
# ext4 skips block groups it has already trimmed in this mount, so trimming
# without a remount leaves most of the freed blocks holding stale data.
umount "$root"
mount "$rootdev" "$root"
fstrim "$root"
umount "$root"
losetup -d "$loop"
loop=""

# Same settings as osbuild's zstd stage.
zstd -T0 -1 -qf "$raw" -o "$work/out.raw.zst"
mv -f "$work/out.raw.zst" "$IMAGE"
