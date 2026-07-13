#!/bin/sh
# Refresh the boot initramfs after a radeon-unified module (un)install.
#
# A bare `dkms install` writes only /lib/modules and runs depmod; it never
# rebuilds the boot initramfs, so the freshly built radeon module does not reach
# the boot image and the next boot loads the previous one.  On a Limine system
# the initramfs is deployed to the ESP under a machine-id path and Limine
# verifies it against a BLAKE2 hash recorded in limine.conf, so the regenerator
# must rebuild, redeploy, and rehash together: a plain `mkinitcpio -P` leaves the
# ESP copy and the hash stale, and the next boot either loads the old module or
# fails Limine's hash check.  Prefer the bootloader-aware generator and fall
# back across distributions.  DKMS runs POST_INSTALL as root, so no escalation.
set -eu

log() { echo "radeon-unified: $*" >&2; }

# Inside a libalpm transaction DKMS builds one kernel at a time with
# --no-depmod, so at POST_INSTALL time the other kernels' modules.dep still
# reference module files the transaction has already deleted; regenerating
# every initramfs here fails with "file not found" on those kernels and
# contends with the bootloader tool's global lock.
#
# Defer only when a PostTransaction regenerator is installed that already
# triggers on this package's usr/src/*/dkms.conf path:
#   - stock 90-mkinitcpio-install.hook -> mkinitcpio -P for non-kernel targets
#   - limine-mkinitcpio-hook's override at /etc/pacman.d/hooks/90-mkinitcpio-install.hook
#     -> full rebuild + ESP deploy + hash for the same non-kernel targets
# When neither hook is present (dracut-only, update-initramfs-only, or a host
# without mkinitcpio hooks), refresh immediately so a DKMS-only pacman
# transaction still updates the boot image.
post_tx_regenerator_present() {
	[ -e /etc/pacman.d/hooks/90-mkinitcpio-install.hook ] && return 0
	[ -e /usr/share/libalpm/hooks/90-mkinitcpio-install.hook ] && return 0
	return 1
}

if [ -e /var/lib/pacman/db.lck ] && post_tx_regenerator_present; then
	log "pacman transaction active; deferring initramfs refresh to PostTransaction mkinitcpio/limine hook (triggers on usr/src/*/dkms.conf)"
	exit 0
fi

if [ -e /var/lib/pacman/db.lck ]; then
	log "pacman transaction active but no mkinitcpio/limine PostTransaction hook found; refreshing now so the boot image is not left stale"
fi

if command -v limine-mkinitcpio >/dev/null 2>&1; then
	log "initramfs refresh via limine-mkinitcpio (mkinitcpio + ESP deploy + hash)"
	limine-mkinitcpio
elif command -v mkinitcpio >/dev/null 2>&1 && command -v limine-update >/dev/null 2>&1; then
	log "initramfs refresh via mkinitcpio -P then limine-update"
	mkinitcpio -P
	limine-update
elif command -v update-initramfs >/dev/null 2>&1; then
	log "initramfs refresh via update-initramfs -u (Debian/Ubuntu)"
	update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
	log "initramfs refresh via dracut --regenerate-all --force"
	dracut --regenerate-all --force
elif command -v mkinitcpio >/dev/null 2>&1; then
	log "initramfs refresh via mkinitcpio -P"
	mkinitcpio -P
else
	log "WARNING: no known initramfs generator; rebuild the boot image manually"
fi
