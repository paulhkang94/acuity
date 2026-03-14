"""
Unit tests for scripts/hidpi.py.

Run with: pytest tests/test_hidpi.py
All tests pass without any display hardware.
"""

import plistlib
import struct
import sys
from pathlib import Path


# Allow importing from scripts/ regardless of working directory
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

import hidpi  # noqa: E402


# ---------------------------------------------------------------------------
# encode_hidpi_entry
# ---------------------------------------------------------------------------


def test_encode_1280x720():
    entry = hidpi.encode_hidpi_entry(1280, 720)
    assert len(entry) == 12
    pw, ph, flag = struct.unpack(">III", entry)
    assert pw == 2560
    assert ph == 1440
    assert flag == 1


def test_encode_1920x1080():
    entry = hidpi.encode_hidpi_entry(1920, 1080)
    assert len(entry) == 12
    pw, ph, flag = struct.unpack(">III", entry)
    assert pw == 3840
    assert ph == 2160
    assert flag == 1


# ---------------------------------------------------------------------------
# get_resolution_ladder — known resolutions
# ---------------------------------------------------------------------------


def test_known_ladder_2560x1440_all():
    ladder = hidpi.get_resolution_ladder(2560, 1440, "all")
    assert len(ladder) >= 4
    assert (1920, 1080) in ladder
    assert (1280, 720) in ladder


def test_known_ladder_2560x1440_2x():
    ladder = hidpi.get_resolution_ladder(2560, 1440, "2x")
    assert len(ladder) == 1
    assert ladder[0] == (1280, 720)


def test_known_ladder_3840x2160_all():
    ladder = hidpi.get_resolution_ladder(3840, 2160, "all")
    assert (1920, 1080) in ladder
    assert (2560, 1440) in ladder


# ---------------------------------------------------------------------------
# get_resolution_ladder — fallback / custom resolutions
# ---------------------------------------------------------------------------


def test_fallback_ladder_custom_resolution():
    # 2560x1080 is not in RESOLUTION_LADDERS
    ladder = hidpi.get_resolution_ladder(2560, 1080, "all")
    assert len(ladder) >= 3
    # All entries must be at least the minimum dimensions
    for w, h in ladder:
        assert w >= hidpi.MIN_WIDTH
        assert h >= hidpi.MIN_HEIGHT


# ---------------------------------------------------------------------------
# get_resolution_ladder — preset 1.5x
# ---------------------------------------------------------------------------


def test_preset_1_5x():
    ladder = hidpi.get_resolution_ladder(2560, 1440, "1.5x")
    assert len(ladder) == 1
    target_w = 2560 / 1.5
    target_h = 1440 / 1.5
    (w, h) = ladder[0]
    # The returned entry should be the closest one in the known ladder
    known = hidpi.RESOLUTION_LADDERS[(2560, 1440)]
    best = min(known, key=lambda r: abs(r[0] - target_w) + abs(r[1] - target_h))
    assert (w, h) == best


# ---------------------------------------------------------------------------
# write_hidpi_plist / plist round-trip
# ---------------------------------------------------------------------------


def test_plist_roundtrip(tmp_path, monkeypatch):
    # Redirect OVERRIDES_DIR to a temp directory so no root needed
    monkeypatch.setattr(hidpi, "OVERRIDES_DIR", tmp_path)

    vendor_id = 0x10AC
    product_id = 0x41DA
    name = "Test Display"
    resolutions = [(1920, 1080), (1280, 720), (1024, 576)]

    path = hidpi.write_hidpi_plist(vendor_id, product_id, name, resolutions)
    assert path.exists()

    with open(path, "rb") as f:
        data = plistlib.load(f)

    entries = data["scale-resolutions"]
    assert len(entries) == len(resolutions)

    for entry in entries:
        assert isinstance(entry, bytes)
        assert len(entry) == 12

    # Verify each decoded entry matches expected physical dimensions
    for i, (lw, lh) in enumerate(resolutions):
        pw, ph, flag = struct.unpack(">III", entries[i])
        assert pw == lw * 2
        assert ph == lh * 2
        assert flag == 1


# ---------------------------------------------------------------------------
# plist keys
# ---------------------------------------------------------------------------


def test_plist_keys(tmp_path, monkeypatch):
    monkeypatch.setattr(hidpi, "OVERRIDES_DIR", tmp_path)

    vendor_id = 0x1234
    product_id = 0x5678
    name = "Key Check Display"
    resolutions = [(1920, 1080)]

    path = hidpi.write_hidpi_plist(vendor_id, product_id, name, resolutions)

    with open(path, "rb") as f:
        data = plistlib.load(f)

    required_keys = {
        "DisplayVendorID",
        "DisplayProductID",
        "DisplayProductName",
        "scale-resolutions",
        "target-default-ppmm",
    }
    for key in required_keys:
        assert key in data, f"Missing required plist key: {key}"

    assert data["DisplayVendorID"] == vendor_id
    assert data["DisplayProductID"] == product_id
    assert data["DisplayProductName"] == name
    assert abs(data["target-default-ppmm"] - hidpi.TARGET_PPMM) < 1e-9
