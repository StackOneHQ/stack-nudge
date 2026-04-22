"""Entry point for `python -m stackvox`."""

from __future__ import annotations

import sys

from stackvox.cli import main

if __name__ == "__main__":
    sys.exit(main())
