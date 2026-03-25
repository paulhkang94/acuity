#!/usr/bin/env python3
"""MCP server exposing acuity CLI as MCP tools over stdio (JSON-RPC 2.0)."""

import json
import shutil
import subprocess
import sys

PROTOCOL_VERSION = "2024-11-05"

TOOLS = [
    {
        "name": "list_displays",
        "description": "List all connected external displays with vendor/product IDs, native resolution, and HiDPI status.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "enable_hidpi",
        "description": (
            "Enable HiDPI (Retina) scaling on external displays. Writes override plists to "
            "/Library/Displays/. Requires sudo/root — either run this server as root, or add "
            "'username ALL=(ALL) NOPASSWD: /usr/local/bin/acuity' to sudoers. "
            "Reboot required to activate."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "display": {
                    "type": "string",
                    "description": "Display ID as 0xVID:0xPID (e.g. 0x10ac:0x41da). Omit for all displays.",
                },
                "preset": {
                    "type": "string",
                    "enum": ["2x", "1.5x", "all"],
                    "default": "all",
                    "description": "Resolution ladder preset. 'all' is recommended.",
                },
            },
        },
    },
    {
        "name": "disable_hidpi",
        "description": (
            "Remove HiDPI override plists. Requires sudo/root — either run this server as root, or "
            "add 'username ALL=(ALL) NOPASSWD: /usr/local/bin/acuity' to sudoers. "
            "Reboot required to deactivate."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "display": {
                    "type": "string",
                    "description": "Display ID as 0xVID:0xPID. Omit for all displays.",
                }
            },
        },
    },
    {
        "name": "get_status",
        "description": "Show detailed HiDPI status for all external displays, including current resolution and override contents.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "set_brightness",
        "description": "Set display brightness via DDC/CI (Apple Silicon only).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "value": {"type": "integer", "minimum": 0, "maximum": 100},
                "display": {
                    "type": "string",
                    "description": "Display ID as 0xVID:0xPID. Omit for first external display.",
                },
            },
            "required": ["value"],
        },
    },
    {
        "name": "set_contrast",
        "description": "Set display contrast via DDC/CI (Apple Silicon only).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "value": {"type": "integer", "minimum": 0, "maximum": 100},
                "display": {"type": "string"},
            },
            "required": ["value"],
        },
    },
]


def find_cli() -> str:
    return shutil.which("acuity") or "/usr/local/bin/acuity"


def run(cmd: list[str], use_sudo: bool = False) -> dict:
    if use_sudo:
        cmd = ["sudo"] + cmd
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        return {
            "success": result.returncode == 0,
            "output": result.stdout.strip(),
            "error": result.stderr.strip() if result.returncode != 0 else "",
        }
    except FileNotFoundError as e:
        return {"success": False, "output": "", "error": str(e)}
    except Exception as e:
        return {"success": False, "output": "", "error": str(e)}


def tool_list_displays(_args: dict) -> str:
    cli = find_cli()
    result = subprocess.run([cli, "list", "--json"], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return json.dumps({"error": result.stderr.strip()})


def tool_enable_hidpi(args: dict) -> str:
    cli = find_cli()
    cmd = [cli, "enable"]
    display = args.get("display")
    if display:
        # Strip leading 0x prefix from each component if present; CLI expects VID:PID
        cmd += ["--display", display]
    else:
        cmd += ["--all"]
    preset = args.get("preset", "all")
    cmd += [f"--preset={preset}"]
    return json.dumps(run(cmd, use_sudo=True))


def tool_disable_hidpi(args: dict) -> str:
    cli = find_cli()
    cmd = [cli, "disable"]
    display = args.get("display")
    if display:
        cmd += ["--display", display]
    else:
        cmd += ["--all"]
    return json.dumps(run(cmd, use_sudo=True))


def tool_get_status(_args: dict) -> str:
    cli = find_cli()
    result = subprocess.run([cli, "status"], capture_output=True, text=True)
    return json.dumps(
        {
            "success": result.returncode == 0,
            "output": result.stdout.strip(),
            "error": result.stderr.strip() if result.returncode != 0 else "",
        }
    )


def tool_set_brightness(args: dict) -> str:
    cli = find_cli()
    value = str(args["value"])
    cmd = [cli, "brightness", value]
    display = args.get("display")
    if display:
        cmd += ["--display", display]
    return json.dumps(run(cmd))


def tool_set_contrast(args: dict) -> str:
    cli = find_cli()
    value = str(args["value"])
    cmd = [cli, "contrast", value]
    display = args.get("display")
    if display:
        cmd += ["--display", display]
    return json.dumps(run(cmd))


TOOL_HANDLERS = {
    "list_displays": tool_list_displays,
    "enable_hidpi": tool_enable_hidpi,
    "disable_hidpi": tool_disable_hidpi,
    "get_status": tool_get_status,
    "set_brightness": tool_set_brightness,
    "set_contrast": tool_set_contrast,
}


def make_response(request_id, result) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def make_error(request_id, code: int, message: str) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


def handle_request(request: dict):
    method = request.get("method", "")
    request_id = request.get("id")
    params = request.get("params") or {}

    if method == "initialize":
        return make_response(
            request_id,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "acuity", "version": "0.1.0"},
            },
        )

    if method == "notifications/initialized":
        return None

    if method == "tools/list":
        return make_response(request_id, {"tools": TOOLS})

    if method == "tools/call":
        tool_name = params.get("name", "")
        tool_args = params.get("arguments") or {}
        handler = TOOL_HANDLERS.get(tool_name)
        if handler is None:
            return make_error(request_id, -32601, f"Unknown tool: {tool_name}")
        try:
            result_text = handler(tool_args)
        except Exception as e:
            result_text = json.dumps({"success": False, "error": str(e)})
        return make_response(
            request_id, {"content": [{"type": "text", "text": result_text}]}
        )

    return make_error(request_id, -32601, f"Method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            error = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {e}"},
            }
            sys.stdout.write(json.dumps(error) + "\n")
            sys.stdout.flush()
            continue
        response = handle_request(request)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
