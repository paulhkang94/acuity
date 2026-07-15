#!/usr/bin/env python3
"""DEPRECATED: hidpi.py has been replaced by the `acuity` CLI.

This script was a Python twin of the Swift core and had already drifted
from it (e.g. the QHD resolution ladder here lacked (1600, 900) which the
Swift implementation ships). The Swift CLI is the single source of truth.

The old implementation is preserved in git history:
    git log -- scripts/hidpi.py
"""

import sys


def main() -> int:
    sys.stderr.write(
        "hidpi.py is deprecated and no longer functional.\n"
        "Use the `acuity` CLI instead:\n"
        "  acuity list\n"
        "  sudo acuity enable --all\n"
        "  sudo acuity disable --all\n"
        "Install: brew install --cask paulhkang94/acuity/acuity\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
