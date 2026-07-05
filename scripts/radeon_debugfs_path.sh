# shellcheck shell=sh
# Resolve a radeon debugfs node name to its actual path.
#
# Radeon debugfs nodes normally live under /sys/kernel/debug/dri/<minor>/.
# Some rebuilt driver paths register RS480 nodes before the DRM minor debugfs
# root is available, which places those nodes under /sys/kernel/debug/.  Tooling
# accepts both layouts while deriving the exact node path at runtime.
#
# Usage:  node=$(radeon_debugfs_path radeon_rs480_cp_me_ram_dump) || exit 1
# Prints the resolved absolute path on stdout; returns non-zero if absent.
radeon_debugfs_path() {
	_rdp_name="$1"
	if [ -z "$_rdp_name" ]; then
		echo "radeon_debugfs_path: missing node name" >&2
		return 2
	fi
	case "$_rdp_name" in
		*/*)
			echo "radeon_debugfs_path: invalid node name: path separators are not allowed" >&2
			return 2
			;;
		. | ..)
			echo "radeon_debugfs_path: invalid node name: dot path components are not allowed" >&2
			return 2
			;;
	esac
	# Preferred: per-minor location (numeric minor or PCI-addressed dir).
	for _rdp_dir in /sys/kernel/debug/dri/*/; do
		if [ -e "${_rdp_dir}${_rdp_name}" ]; then
			printf '%s\n' "${_rdp_dir}${_rdp_name}"
			return 0
		fi
	done
	# Fallback: top-level registration before the DRM minor root exists.
	if [ -e "/sys/kernel/debug/${_rdp_name}" ]; then
		printf '%s\n' "/sys/kernel/debug/${_rdp_name}"
		return 0
	fi
	echo "radeon_debugfs_path: node not found: ${_rdp_name}" >&2
	return 1
}
