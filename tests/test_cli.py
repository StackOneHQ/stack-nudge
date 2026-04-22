"""CLI argument parsing — no engine loaded, no audio played."""

from __future__ import annotations

import pytest

from stackvox import cli


def test_bare_text_routes_to_speak(mocker):
    speak = mocker.patch.object(cli, "_cmd_speak", return_value=0)
    mocker.patch.object(cli.sys, "argv", ["stackvox", "hello world"])
    assert cli.main() == 0
    args = speak.call_args.args[0]
    assert args.cmd == "speak"
    assert args.text == "hello world"


def test_speak_subcommand_parses_voice_and_speed(mocker):
    speak = mocker.patch.object(cli, "_cmd_speak", return_value=0)
    mocker.patch.object(cli.sys, "argv", ["stackvox", "speak", "--voice", "bf_emma", "--speed", "1.2", "hi"])
    assert cli.main() == 0
    args = speak.call_args.args[0]
    assert args.voice == "bf_emma"
    assert args.speed == pytest.approx(1.2)
    assert args.text == "hi"


def test_no_subcommand_prints_help(mocker, capsys):
    mocker.patch.object(cli.sys, "argv", ["stackvox"])
    assert cli.main() == 1
    captured = capsys.readouterr()
    assert "usage: stackvox" in captured.out


def test_unknown_subcommand_treated_as_speak_text(mocker):
    """`stackvox foo` is treated as `stackvox speak foo`, not an error."""
    speak = mocker.patch.object(cli, "_cmd_speak", return_value=0)
    mocker.patch.object(cli.sys, "argv", ["stackvox", "hello"])
    cli.main()
    assert speak.call_args.args[0].text == "hello"
