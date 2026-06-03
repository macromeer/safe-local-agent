import os
import subprocess
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP


mcp = FastMCP("local-agent-tools")
WORKSPACE_ROOT = Path(os.environ.get("MCP_WORKSPACE_ROOT", "/opt/safe-local-agent")).resolve()
MAX_FILE_BYTES = 1_000_000


def _resolve_in_workspace(path: str) -> Path:
    candidate = Path(path)
    resolved = (candidate if candidate.is_absolute() else WORKSPACE_ROOT / candidate).resolve()
    if resolved != WORKSPACE_ROOT and WORKSPACE_ROOT not in resolved.parents:
        raise ValueError(f"Path '{path}' is outside workspace root '{WORKSPACE_ROOT}'")
    return resolved


@mcp.tool()
def workspace_info() -> dict[str, str]:
    """Return key runtime paths for this MCP server."""
    return {
        "workspace_root": str(WORKSPACE_ROOT),
        "server_cwd": os.getcwd(),
        "python_executable": os.sys.executable,
    }


@mcp.tool()
def list_files(path: str = ".", include_hidden: bool = False, max_entries: int = 200) -> list[str]:
    """List files and directories relative to the workspace."""
    root = _resolve_in_workspace(path)
    if not root.exists():
        raise ValueError(f"Path not found: {path}")
    if not root.is_dir():
        raise ValueError(f"Path is not a directory: {path}")

    entries: list[str] = []
    for child in sorted(root.iterdir(), key=lambda p: p.name):
        name = child.name
        if not include_hidden and name.startswith("."):
            continue
        rel = child.relative_to(WORKSPACE_ROOT)
        suffix = "/" if child.is_dir() else ""
        entries.append(f"{rel}{suffix}")
        if len(entries) >= max_entries:
            break
    return entries


@mcp.tool()
def read_file_lines(path: str, start_line: int = 1, end_line: int = 200) -> str:
    """Read a UTF-8 text file line range (1-based, inclusive)."""
    if start_line < 1 or end_line < start_line:
        raise ValueError("Invalid line range")

    target = _resolve_in_workspace(path)
    if not target.exists() or not target.is_file():
        raise ValueError(f"File not found: {path}")
    if target.stat().st_size > MAX_FILE_BYTES:
        raise ValueError("File too large for this tool")

    lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
    segment = lines[start_line - 1 : end_line]
    return "\n".join(segment)


@mcp.tool()
def grep_text(query: str, path: str = ".", case_sensitive: bool = False, max_results: int = 50) -> list[dict[str, Any]]:
    """Search text in workspace files and return file/line matches."""
    if not query:
        raise ValueError("Query cannot be empty")

    root = _resolve_in_workspace(path)
    if not root.exists():
        raise ValueError(f"Path not found: {path}")

    needle = query if case_sensitive else query.lower()
    results: list[dict[str, Any]] = []

    files = [root] if root.is_file() else [p for p in root.rglob("*") if p.is_file()]
    for file_path in files:
        if file_path.stat().st_size > MAX_FILE_BYTES:
            continue
        text = file_path.read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), start=1):
            hay = line if case_sensitive else line.lower()
            if needle in hay:
                results.append(
                    {
                        "path": str(file_path.relative_to(WORKSPACE_ROOT)),
                        "line": i,
                        "text": line.strip(),
                    }
                )
                if len(results) >= max_results:
                    return results
    return results


@mcp.tool()
def write_text_file(path: str, content: str, overwrite: bool = False) -> str:
    """Write UTF-8 text file inside workspace (create parent directories if needed)."""
    target = _resolve_in_workspace(path)
    if target.exists() and not overwrite:
        raise ValueError(f"File already exists: {path}. Use overwrite=true to replace it.")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    return str(target.relative_to(WORKSPACE_ROOT))


@mcp.tool()
def run_local_command(command: str, cwd: str = ".", timeout_seconds: int = 30) -> dict[str, Any]:
    """Run a shell command within the workspace and return exit code/stdout/stderr."""
    work_dir = _resolve_in_workspace(cwd)
    if not work_dir.is_dir():
        raise ValueError(f"cwd is not a directory: {cwd}")

    proc = subprocess.run(
        command,
        shell=True,
        cwd=work_dir,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
    return {
        "cwd": str(work_dir.relative_to(WORKSPACE_ROOT)),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[:12000],
        "stderr": proc.stderr[:12000],
    }


if __name__ == "__main__":
    mcp.run()
