"""Filesystem paths used across stackvox: model cache, daemon socket, pid file.

Centralising these avoids leaking private helpers between modules and keeps
the `STACKVOX_CACHE_DIR` / `STACKVOX_SOCKET` override rules in one place.
"""

from __future__ import annotations

import os
from pathlib import Path


def cache_dir() -> Path:
    """Directory holding the model, voice pack, socket, and pid file.

    Honours `STACKVOX_CACHE_DIR`; defaults to `~/.cache/stackvox`.
    """
    override = os.environ.get("STACKVOX_CACHE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".cache" / "stackvox"


def socket_path() -> Path:
    """Unix socket the daemon listens on. Lives under `cache_dir()`.

    Note: the bash `stackvox-say` helper honours `STACKVOX_SOCKET` so users
    can point it at a socket on a different machine / mount — the Python
    daemon does not, since it owns the socket and derives it from its own
    cache dir.
    """
    return cache_dir() / "daemon.sock"


def pid_path() -> Path:
    return cache_dir() / "daemon.pid"
