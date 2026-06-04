from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from built_in_servers import SERVER_SPECS


def stdio_compatible_server_names() -> list[str]:
    names: list[str] = []
    for name, spec in SERVER_SPECS.items():
        if spec.kind == "asgi":
            continue
        if spec.transport != "stdio":
            continue
        names.append(name)
    return sorted(names)


def all_server_names() -> list[str]:
    return sorted(SERVER_SPECS.keys())


def build_server_entry(project_dir: Path, launcher_path: Path, server_name: str, timeout: int) -> dict[str, Any]:
    return {
        "disabled": False,
        "transportType": "stdio",
        "timeout": timeout,
        "command": "uv",
        "args": [
            "run",
            "--project",
            str(project_dir),
            "python",
            str(launcher_path),
            server_name,
        ],
    }


def build_config(project_dir: Path, launcher_path: Path, server_names: list[str], timeout: int) -> dict[str, Any]:
    mcp_servers: dict[str, Any] = {}
    for server_name in server_names:
        key = f"builtin-{server_name}"
        mcp_servers[key] = build_server_entry(project_dir, launcher_path, server_name, timeout)
    return {"mcpServers": mcp_servers}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Cline mcpServers JSON for stdio-compatible built-in servers."
    )
    default_project_dir = Path(__file__).resolve().parent
    default_launcher = default_project_dir / "built_in_servers.py"

    parser.add_argument(
        "--project-dir",
        default=str(default_project_dir),
        help="Path to mcp-server-local-agent project directory.",
    )
    parser.add_argument(
        "--launcher-path",
        default=str(default_launcher),
        help="Path to built_in_servers.py launcher.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Timeout value for generated Cline server entries.",
    )
    parser.add_argument(
        "--servers",
        nargs="+",
        help="Explicit list of built-in server names to include.",
    )
    parser.add_argument(
        "--include-non-stdio",
        action="store_true",
        help="Include names that are not stdio-compatible. Use only if you know how to route them.",
    )
    parser.add_argument(
        "--output",
        help="Optional file path to write JSON output.",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    project_dir = Path(args.project_dir).resolve()
    launcher_path = Path(args.launcher_path).resolve()

    if args.servers:
        selected = sorted(set(args.servers))
    elif args.include_non_stdio:
        selected = all_server_names()
    else:
        selected = stdio_compatible_server_names()

    unknown = [name for name in selected if name not in SERVER_SPECS]
    if unknown:
        raise SystemExit(f"Unknown server names: {', '.join(unknown)}")

    config = build_config(project_dir, launcher_path, selected, args.timeout)
    rendered = json.dumps(config, indent=2)

    if args.output:
        output_path = Path(args.output).resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)

    skipped_non_stdio = sorted(set(all_server_names()) - set(stdio_compatible_server_names()))
    if not args.include_non_stdio and not args.servers and skipped_non_stdio:
        print(
            "\n# Skipped non-stdio built-in servers: " + ", ".join(skipped_non_stdio),
            file=sys.stderr,
            flush=True,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
