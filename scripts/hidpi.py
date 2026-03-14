#!/usr/bin/env python3
"""
hidpi.py — Enable HiDPI (Retina) scaling on external displays on macOS.

Usage:
    sudo python3 hidpi.py enable
    sudo python3 hidpi.py enable --display 0x10ac:0x41da
    sudo python3 hidpi.py enable --preset 2x|1.5x|all
    sudo python3 hidpi.py disable
    python3 hidpi.py list
    python3 hidpi.py list --json
    python3 hidpi.py status
"""

import argparse
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

OVERRIDES_DIR = Path("/Library/Displays/Contents/Resources/Overrides")
WINDOWSERVER_PREFS = "/Library/Preferences/com.apple.windowserver"

RESOLUTION_LADDERS = {
    (3840, 2160): [
        (3840, 2160),
        (3200, 1800),
        (2560, 1440),
        (1920, 1080),
        (1600, 900),
        (1280, 720),
    ],
    (2560, 1600): [(2560, 1600), (1920, 1200), (1680, 1050), (1280, 800), (1024, 640)],
    (2560, 1440): [
        (2560, 1440),
        (2048, 1152),
        (1920, 1080),
        (1680, 945),
        (1440, 810),
        (1280, 720),
        (1024, 576),
        (960, 540),
    ],
    (3440, 1440): [(3440, 1440), (2560, 1080), (1720, 720), (1280, 540)],
    (1920, 1080): [(1920, 1080), (1600, 900), (1280, 720), (1024, 576), (960, 540)],
    (2048, 1152): [(2048, 1152), (1920, 1080), (1600, 900), (1280, 720)],
}

FALLBACK_STEPS = [1.0, 0.8, 0.75, 0.667, 0.5, 0.375, 0.25]
MIN_WIDTH = 640
MIN_HEIGHT = 400
TARGET_PPMM = 10.069930100000001


def encode_hidpi_entry(logical_w: int, logical_h: int) -> bytes:
    """Encode a single HiDPI resolution entry as 12 bytes (big-endian)."""
    return struct.pack(">III", logical_w * 2, logical_h * 2, 1)


def compute_fallback_ladder(native_w: int, native_h: int) -> list:
    """Compute a fallback resolution ladder for non-standard native resolutions."""
    entries = []
    seen = set()
    for step in FALLBACK_STEPS:
        w = int(native_w * step)
        h = int(native_h * step)
        # Round down to even numbers
        w = w - (w % 2)
        h = h - (h % 2)
        if w < MIN_WIDTH or h < MIN_HEIGHT:
            continue
        if (w, h) in seen:
            continue
        seen.add((w, h))
        entries.append((w, h))
    return entries


def get_resolution_ladder(native_w: int, native_h: int, preset: str = "all") -> list:
    """Return the list of logical resolutions to encode for a given native resolution and preset."""
    if preset == "2x":
        return [(native_w // 2, native_h // 2)]

    if (native_w, native_h) in RESOLUTION_LADDERS:
        ladder = RESOLUTION_LADDERS[(native_w, native_h)]
    else:
        ladder = compute_fallback_ladder(native_w, native_h)

    if preset == "1.5x":
        target_w = native_w / 1.5
        target_h = native_h / 1.5
        best = min(ladder, key=lambda r: abs(r[0] - target_w) + abs(r[1] - target_h))
        return [best]

    return ladder


def _parse_id(value: str) -> int:
    """Parse a vendor/product ID that may be hex ('0x10ac') or decimal."""
    value = value.strip()
    if value.startswith("0x") or value.startswith("0X"):
        return int(value, 16)
    return int(value, 0)


def detect_external_displays() -> list:
    """
    Return a list of dicts with keys: vendor_id, product_id, name, width, height.
    Uses system_profiler SPDisplaysDataType -json.
    """
    try:
        result = subprocess.run(
            ["system_profiler", "SPDisplaysDataType", "-json"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            print(f"⚠ system_profiler failed: {result.stderr.strip()}", file=sys.stderr)
            return []
        data = json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError) as e:
        print(f"⚠ Failed to query displays: {e}", file=sys.stderr)
        return []

    displays = []
    for gpu in data.get("SPDisplaysDataType", []):
        for display in gpu.get("spdisplays_ndrvs", []):
            # Skip built-in displays
            if display.get("spdisplays_display_type") == "spdisplays_built-in_display":
                continue

            vendor_id = None
            product_id = None

            # Try explicit vendor/product ID fields first
            vid_raw = display.get("_spdisplays_vendorid") or display.get(
                "spdisplays_vendorid"
            )
            pid_raw = display.get("_spdisplays_productid") or display.get(
                "spdisplays_productid"
            )

            if vid_raw is not None and pid_raw is not None:
                try:
                    vendor_id = _parse_id(str(vid_raw))
                    product_id = _parse_id(str(pid_raw))
                except ValueError:
                    pass

            # Fall back to parsing display name for pattern like "Display 10ac:41da"
            if vendor_id is None or product_id is None:
                name = display.get("_name", "") or display.get(
                    "spdisplays_display_name", ""
                )
                m = re.search(r"([0-9a-fA-F]{4}):([0-9a-fA-F]{4})", name)
                if m:
                    vendor_id = int(m.group(1), 16)
                    product_id = int(m.group(2), 16)

            if vendor_id is None or product_id is None:
                continue

            # Parse resolution
            width = None
            height = None
            for key in ("spdisplays_resolution", "_spdisplays_resolution"):
                res_str = display.get(key, "")
                if res_str:
                    m = re.search(r"(\d+)\s*[x×]\s*(\d+)", res_str)
                    if m:
                        width = int(m.group(1))
                        height = int(m.group(2))
                        break

            name = (
                display.get("_name")
                or display.get("spdisplays_display_name")
                or f"Display {vendor_id:04x}:{product_id:04x}"
            )

            displays.append(
                {
                    "vendor_id": vendor_id,
                    "product_id": product_id,
                    "name": name,
                    "width": width,
                    "height": height,
                }
            )

    return displays


def override_path(vendor_id: int, product_id: int) -> Path:
    """Return the plist path for a given vendor/product ID pair."""
    vendor_dir = OVERRIDES_DIR / f"DisplayVendorID-{vendor_id:x}"
    return vendor_dir / f"DisplayProductID-{product_id:x}"


def write_hidpi_plist(
    vendor_id: int, product_id: int, name: str, resolutions: list
) -> Path:
    """
    Write the EDID override plist for a display.
    resolutions: list of (logical_w, logical_h) tuples.
    Returns the path written.
    """
    scale_data = [encode_hidpi_entry(w, h) for w, h in resolutions]

    plist_data = {
        "DisplayVendorID": vendor_id,
        "DisplayProductID": product_id,
        "DisplayProductName": name,
        "scale-resolutions": scale_data,
        "target-default-ppmm": TARGET_PPMM,
    }

    path = override_path(vendor_id, product_id)
    path.parent.mkdir(parents=True, exist_ok=True)

    with open(path, "wb") as f:
        plistlib.dump(plist_data, f, fmt=plistlib.FMT_XML)

    return path


def read_hidpi_plist(vendor_id: int, product_id: int):
    """Read and return the override plist dict, or None if it doesn't exist."""
    path = override_path(vendor_id, product_id)
    if not path.exists():
        return None
    with open(path, "rb") as f:
        return plistlib.load(f)


def enable_windowserver_flag():
    """Enable the WindowServer HiDPI flag."""
    subprocess.run(
        [
            "defaults",
            "write",
            WINDOWSERVER_PREFS,
            "DisplayResolutionEnabled",
            "-bool",
            "YES",
        ],
        check=True,
    )


def parse_display_filter(display_arg: str) -> tuple:
    """Parse '0x10ac:0x41da' or '10ac:41da' into (vendor_id, product_id) ints."""
    parts = display_arg.strip().split(":")
    if len(parts) != 2:
        raise ValueError(
            f"Invalid display format: {display_arg!r}. Expected VID:PID (e.g. 0x10ac:0x41da)"
        )
    return _parse_id(parts[0]), _parse_id(parts[1])


def cmd_list(args):
    displays = detect_external_displays()

    if args.json:
        output = []
        for d in displays:
            output.append(
                {
                    "vendor_id": f"0x{d['vendor_id']:04x}",
                    "product_id": f"0x{d['product_id']:04x}",
                    "name": d["name"],
                    "resolution": f"{d['width']}x{d['height']}" if d["width"] else None,
                    "hidpi_override": override_path(
                        d["vendor_id"], d["product_id"]
                    ).exists(),
                }
            )
        print(json.dumps(output, indent=2))
        return

    if not displays:
        print("⚠ No external displays detected.")
        return

    print(f"Found {len(displays)} external display(s):\n")
    for i, d in enumerate(displays):
        res_str = f"{d['width']}×{d['height']}" if d["width"] else "unknown resolution"
        override_exists = override_path(d["vendor_id"], d["product_id"]).exists()
        hidpi_marker = " [HiDPI override active]" if override_exists else ""
        print(f"  [{i}] {d['name']}")
        print(f"       VID:PID  0x{d['vendor_id']:04x}:0x{d['product_id']:04x}")
        print(f"       Resolution {res_str}{hidpi_marker}")


def cmd_status(args):
    displays = detect_external_displays()

    if not displays:
        print("⚠ No external displays detected.")
        return

    print("HiDPI Status\n")
    for d in displays:
        path = override_path(d["vendor_id"], d["product_id"])
        res_str = f"{d['width']}×{d['height']}" if d["width"] else "unknown"
        print(
            f"  {d['name']}  (0x{d['vendor_id']:04x}:0x{d['product_id']:04x}, {res_str})"
        )

        if not path.exists():
            print("    ✗ No HiDPI override installed")
            continue

        try:
            with open(path, "rb") as f:
                pdata = plistlib.load(f)
            entries = pdata.get("scale-resolutions", [])
            decoded = []
            for entry in entries:
                if len(entry) >= 12:
                    pw, ph, _ = struct.unpack(">III", entry[:12])
                    decoded.append(f"{pw // 2}×{ph // 2}")
            print(
                f"    ✓ HiDPI override active — {len(entries)} resolution(s): {', '.join(decoded)}"
            )
        except Exception as e:
            print(f"    ⚠ Override file exists but could not be read: {e}")


def cmd_enable(args):
    if os.geteuid() != 0:
        print("✗ This command must be run as root. Use: sudo python3 hidpi.py enable")
        sys.exit(1)

    displays = detect_external_displays()

    if not displays:
        print("⚠ No external displays detected.")
        sys.exit(1)

    # Filter by --display if provided
    if args.display:
        try:
            filter_vid, filter_pid = parse_display_filter(args.display)
        except ValueError as e:
            print(f"✗ {e}")
            sys.exit(1)
        displays = [
            d
            for d in displays
            if d["vendor_id"] == filter_vid and d["product_id"] == filter_pid
        ]
        if not displays:
            print(f"✗ No external display found matching {args.display}")
            sys.exit(1)

    preset = args.preset

    any_written = False
    for d in displays:
        if not d["width"] or not d["height"]:
            print(f"⚠ {d['name']}: could not determine resolution, skipping")
            continue

        ladder = get_resolution_ladder(d["width"], d["height"], preset)
        if not ladder:
            print(
                f"⚠ {d['name']}: no resolutions computed for preset '{preset}', skipping"
            )
            continue

        path = write_hidpi_plist(d["vendor_id"], d["product_id"], d["name"], ladder)

        res_str = ", ".join(f"{w}×{h}" for w, h in ladder)
        print(f"✓ {d['name']} (0x{d['vendor_id']:04x}:0x{d['product_id']:04x})")
        print(f"   Wrote {len(ladder)} HiDPI resolution(s): {res_str}")
        print(f"   → {path}")
        any_written = True

    if any_written:
        try:
            enable_windowserver_flag()
            print("\n✓ WindowServer DisplayResolutionEnabled set to YES")
        except subprocess.CalledProcessError as e:
            print(f"\n⚠ Could not set WindowServer flag: {e}")

        print("\n  Log out and log back in (or restart) for changes to take effect.")


def cmd_disable(args):
    if os.geteuid() != 0:
        print("✗ This command must be run as root. Use: sudo python3 hidpi.py disable")
        sys.exit(1)

    displays = detect_external_displays()
    removed = 0

    for d in displays:
        path = override_path(d["vendor_id"], d["product_id"])
        if path.exists():
            path.unlink()
            print(
                f"✓ Removed override for {d['name']} (0x{d['vendor_id']:04x}:0x{d['product_id']:04x})"
            )
            # Remove vendor dir if now empty
            try:
                path.parent.rmdir()
            except OSError:
                pass
            removed += 1

    if removed == 0:
        print("⚠ No HiDPI overrides found to remove.")
    else:
        print(f"\n✓ Removed {removed} override(s). Log out and log back in to apply.")


def main():
    parser = argparse.ArgumentParser(
        description="Enable HiDPI (Retina) scaling on external displays.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    subparsers = parser.add_subparsers(dest="command")

    # list
    p_list = subparsers.add_parser("list", help="List external displays")
    p_list.add_argument("--json", action="store_true", help="Output as JSON")

    # status
    subparsers.add_parser("status", help="Show detailed HiDPI status")

    # enable
    p_enable = subparsers.add_parser("enable", help="Enable HiDPI overrides")
    p_enable.add_argument(
        "--display",
        metavar="VID:PID",
        help="Target a specific display (e.g. 0x10ac:0x41da)",
    )
    p_enable.add_argument(
        "--preset",
        choices=["2x", "1.5x", "all"],
        default="all",
        help="Resolution preset (default: all)",
    )

    # disable
    subparsers.add_parser("disable", help="Remove HiDPI overrides")

    args = parser.parse_args()

    if args.command == "list":
        cmd_list(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "enable":
        cmd_enable(args)
    elif args.command == "disable":
        cmd_disable(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
