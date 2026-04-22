"""Pure path-resolution logic — no I/O, no model."""

from __future__ import annotations

from pathlib import Path

from stackvox import paths


def test_cache_dir_default(monkeypatch):
    monkeypatch.delenv("STACKVOX_CACHE_DIR", raising=False)
    actual = paths.cache_dir()
    assert actual == Path.home() / ".cache" / "stackvox"


def test_cache_dir_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("STACKVOX_CACHE_DIR", str(tmp_path / "custom"))
    assert paths.cache_dir() == tmp_path / "custom"


def test_cache_dir_expands_tilde(monkeypatch):
    monkeypatch.setenv("STACKVOX_CACHE_DIR", "~/somewhere")
    assert paths.cache_dir() == Path.home() / "somewhere"


def test_socket_and_pid_live_under_cache_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("STACKVOX_CACHE_DIR", str(tmp_path))
    assert paths.socket_path() == tmp_path / "daemon.sock"
    assert paths.pid_path() == tmp_path / "daemon.pid"
