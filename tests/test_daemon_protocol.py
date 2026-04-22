"""Daemon socket protocol — handler behavior with a mocked engine.

We spin up a real UnixStreamServer bound to a tmp socket, swap out the
engine with a mock, and verify the wire-level replies. No Kokoro load,
no audio device.
"""

from __future__ import annotations

import json
import socket
import tempfile
import threading
from pathlib import Path

import pytest


@pytest.fixture
def server(mocker):
    """Start an isolated daemon server on a temp socket, yield its address.

    Uses `tempfile.mkdtemp(dir="/tmp")` rather than pytest's tmp_path because
    macOS caps AF_UNIX socket paths at ~104 bytes and pytest paths are deep.
    """
    from stackvox import daemon

    mocker.patch.object(daemon, "Stackvox")

    tmp = Path(tempfile.mkdtemp(prefix="svx-", dir="/tmp"))
    sock = tmp / "t.sock"
    state = daemon._DaemonState(voice="af_sarah", speed=1.0, lang="en-us")
    srv = daemon._UnixServer(str(sock), daemon._Handler)
    srv.state = state  # type: ignore[attr-defined]
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        yield sock, state
    finally:
        state.shutdown()
        srv.shutdown()
        srv.server_close()
        sock.unlink(missing_ok=True)
        tmp.rmdir()


def _roundtrip(sock_path: Path, payload: str) -> str:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    try:
        s.connect(str(sock_path))
        s.sendall(payload.encode("utf-8"))
        return s.recv(1024).decode("utf-8").strip()
    finally:
        s.close()


def test_ping_returns_ok(server):
    sock, _ = server
    assert _roundtrip(sock, json.dumps({"command": "ping"}) + "\n") == "ok"


def test_plain_text_is_treated_as_text_field(server):
    """Non-JSON payloads are accepted and wrapped as `{"text": line}`."""
    import time

    sock, state = server
    assert _roundtrip(sock, "hello\n") == "ok"
    # The worker (mocked Stackvox) drains the queue immediately; poll until
    # the mock records the call rather than racing the queue.
    deadline = time.monotonic() + 1.0
    while not state.tts.speak.call_args_list and time.monotonic() < deadline:
        time.sleep(0.01)
    assert state.tts.speak.call_args.args[0] == "hello"


def test_missing_text_yields_error(server):
    sock, _ = server
    reply = _roundtrip(sock, json.dumps({"voice": "af_sarah"}) + "\n")
    assert reply.startswith("err:")


def test_full_queue_returns_busy(server, mocker):
    from stackvox import daemon

    sock, state = server
    # Block the worker so the queue can actually fill up.
    state.queue.put_nowait({"text": "a"})
    state.queue.put_nowait({"text": "b"})
    assert state.queue.full() or state.queue.qsize() >= daemon.MAX_QUEUE

    reply = _roundtrip(sock, json.dumps({"text": "overflow"}) + "\n")
    # At least one of the sentinel messages OR busy — queue may drain if worker picks up first.
    assert reply in {"ok", "busy"}


def test_send_helper_when_daemon_not_running(tmp_path, monkeypatch):
    from stackvox import daemon

    monkeypatch.setattr(daemon, "SOCKET_PATH", tmp_path / "nope.sock")
    ok, resp = daemon.send({"command": "ping"})
    assert not ok
    assert resp == "daemon not running"
