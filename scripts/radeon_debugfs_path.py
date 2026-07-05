"""Resolve a radeon debugfs node name to its actual path.

Radeon debugfs nodes normally live under ``/sys/kernel/debug/dri/<minor>/``.
Some rebuilt driver paths register RS480 nodes before the DRM minor debugfs root
is available, which places those nodes under ``/sys/kernel/debug/``.  Tooling
accepts both layouts while deriving the exact node path at runtime.
"""

from __future__ import annotations

import glob
import os


def radeon_debugfs_path(name: str) -> str:
    """Return the absolute path of a radeon debugfs node, or raise.

    Prefers the per-minor ``/sys/kernel/debug/dri/<minor>/<name>`` location and
    falls back to the top-level ``/sys/kernel/debug/<name>`` placement observed
    when node registration runs before the DRM minor debugfs root exists.
    """
    if not name:
        raise ValueError("radeon_debugfs_path: missing node name")
    if os.sep in name or (os.altsep is not None and os.altsep in name):
        raise ValueError(
            f"radeon_debugfs_path: invalid node name {name!r}: "
            "path separators are not allowed"
        )
    if name in (os.curdir, os.pardir):
        raise ValueError(
            f"radeon_debugfs_path: invalid node name {name!r}: "
            "dot path components are not allowed"
        )
    for minor_dir in sorted(glob.glob("/sys/kernel/debug/dri/*/")):
        candidate = os.path.join(minor_dir, name)
        if os.path.exists(candidate):
            return candidate
    top_level = os.path.join("/sys/kernel/debug", name)
    if os.path.exists(top_level):
        return top_level
    raise FileNotFoundError(f"radeon debugfs node not found: {name}")
