"""Tests for the scripts/hidpi.py deprecation stub.

The former Python implementation was a diverged twin of the Swift core
(its QHD ladder lacked (1600, 900) which the Swift side ships) and was
removed. Its behavioral tests moved with it: the Swift suite covers
encoding (ResolutionEncoderTests), ladders (ResolutionPresetsTests) and
plist writing (PlistWriterTests). What remains real here is the stub
itself: it must fail loudly and point users at the `acuity` CLI.

Run with: python3 -m pytest pytests/ -q
"""

import subprocess
import sys
from pathlib import Path

STUB = Path(__file__).parent.parent / "scripts" / "hidpi.py"


def run_stub(*args):
    return subprocess.run(
        [sys.executable, str(STUB), *args],
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_stub_exits_nonzero():
    result = run_stub()
    assert result.returncode == 1


def test_stub_points_to_acuity_cli():
    result = run_stub()
    output = result.stdout + result.stderr
    assert "deprecated" in output.lower()
    assert "acuity" in output


def test_stub_fails_loudly_on_legacy_invocations():
    # Old invocations like `hidpi.py enable --all` must exit 1 too —
    # never silently no-op for a user following stale instructions.
    for legacy_args in (("enable", "--all"), ("list",), ("disable",)):
        result = run_stub(*legacy_args)
        assert result.returncode == 1, f"legacy args {legacy_args} must fail"
