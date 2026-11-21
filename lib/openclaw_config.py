"""Helpers for the security-relevant parts of an OpenClaw config.

Run as the agent user. Writing is left to `openclaw config set`, which
validates every change against OpenClaw's schema; this only reads the config
and builds the JSON values for it.

  show [CONFIG_PATH]
      key=value lines: tools_profile, browser_enabled, elevated, plugins_allow,
      sandbox_mode, sandbox_network, external_binds, web_search_provider, searxng_url
      (OpenClaw's defaults where a key is not set; "unset" where it has none)
  explain
      reads `openclaw sandbox explain --json` on stdin, prints key=value lines:
      sandboxed, mode, backend, elevated, open_tools, gateway_tools, write_tools,
      shell_tools, mounts (HOST:CONTAINER:ro|rw ...)
  plugins-json ID...
      the JSON list for plugins.allow
  also-allow-json TOOL...
      the JSON list for tools.sandbox.tools.alsoAllow (single tool names, no
      wildcards, groups or tools that act on the gateway itself)
  agent ID
      key=value lines from agents.entries.<ID> in the agent user's config:
      configured, deny, allow_agents, delegate_to, model, binds, external_binds,
      extra_paths
  agents
      reads `openclaw agents list --json` on stdin, prints "ID WORKSPACE
      default|-" per agent
  reply
      reads `openclaw agent --json` on stdin, prints status=..., tools=...,
      error=..., then the agent's reply text
  list-add ITEM... / list-remove ITEM...
      reads a JSON list on stdin (or nothing), prints it with ITEMs added or
      removed. An ITEM starting with { is a JSON object
  put-block FILE NAME
      puts stdin into FILE between safe-local-agents:NAME markers, replacing
      an earlier block (for instructions in a workspace's AGENTS.md)
  check-bind BIND...
      exits non-zero unless every BIND is safe to mount (see sandbox-json)
  sandbox-json NETWORK WORKSPACE UID:GID [BIND...]
      the JSON object for agents.defaults.sandbox (to merge). A BIND is
      HOST:CONTAINER:ro or HOST:CONTAINER:rw, with an absolute HOST outside the
      agent's OpenClaw state and runtime folder (where the Podman socket is).
"""
import json
import os
import re
import sys

DEFAULT_PATH = "~/.openclaw/openclaw.json"
IMAGE = "openclaw-sandbox:trixie-slim"
NETWORKS = ("none", "bridge")
WORKSPACES = ("none", "ro", "rw")
# Tools that act from outside the sandbox (they run in the gateway) and could
# change its setup or schedule work. OpenClaw denies them in sandboxed sessions
# by default; a tools.sandbox.tools policy can let them back in.
CONTROL_TOOLS = ("gateway", "cron", "nodes", "automations")
# Tools that run in the gateway but are useful from a sandboxed session.
# OpenClaw's default sandbox allowlist has none of them.
GATEWAY_TOOLS = ("web_search", "web_fetch", "x_search", "memory_search", "memory_get")
# What the researcher must not have: a shell. (It may write, in its workspace.)
SHELL_TOOLS = ("exec", "process")
WRITE_TOOLS = ("exec", "process", "write", "edit", "apply_patch")
TMPFS = ("/tmp", "/var/tmp")
# Podman runs its init (catatonit) from here; a tmpfs or bind over it makes
# OpenClaw refuse to start the sandbox.
PODMAN_INIT = "/run/podman-init"
# Container paths OpenClaw mounts itself: a bind there would hide them. A bind
# *below* /workspace (like the researcher's /workspace/results) is fine but
# needs OpenClaw's dangerouslyAllowReservedContainerTargets.
OPENCLAW_TARGETS = ("/workspace", "/agent")
OPENCLAW_TREES = ("/workspace/skills", "/workspace/.agents", "/workspace/.openclaw")


def covers(path, target):
    """True if mounting something at path would hide target."""
    path = os.path.normpath(path)
    return target == path or target.startswith(path.rstrip("/") + "/")


def get(cfg, *keys, default=None):
    for k in keys:
        if not isinstance(cfg, dict) or k not in cfg:
            return default
        cfg = cfg[k]
    return cfg


def flag(value):
    return str(value).lower() if isinstance(value, bool) else str(value)


def show(cfg):
    allow = get(cfg, "plugins", "allow", default=[]) or []
    return [
        ("tools_profile", get(cfg, "tools", "profile", default="unset")),
        ("browser_enabled", flag(get(cfg, "browser", "enabled", default=True))),
        ("elevated", flag(get(cfg, "tools", "elevated", "enabled", default=False))),
        ("plugins_allow", ",".join(map(str, allow)) if isinstance(allow, list) else ""),
        ("sandbox_mode", get(cfg, "agents", "defaults", "sandbox", "mode", default="off")),
        ("sandbox_network", get(cfg, "agents", "defaults", "sandbox", "docker", "network", default="none")),
        ("external_binds", flag(get(cfg, "agents", "defaults", "sandbox", "docker",
                                    "dangerouslyAllowExternalBindSources", default=False))),
        ("web_search_provider", get(cfg, "tools", "web", "search", "provider", default="unset")),
        ("searxng_url", get(cfg, "plugins", "entries", "searxng", "config", "webSearch", "baseUrl",
                            default="unset")),
    ]


def explain(report):
    """Summary of `openclaw sandbox explain --json` as (key, value) pairs."""
    if report.get("ok") is False or "sandbox" not in report:
        # e.g. several agents and no --agent: an error, not "not sandboxed"
        msg = str((report.get("error") or {}).get("message", "no sandbox section"))
        return [("sandboxed", "unknown"), ("error", " ".join(msg.split()))]
    sb = report.get("sandbox") or {}
    tools = sb.get("tools") or {}
    allow = tools.get("allow") or []
    deny = tools.get("deny") or []
    if "*" in allow:
        open_tools = [t for t in CONTROL_TOOLS if t not in deny]
    else:
        open_tools = [t for t in CONTROL_TOOLS if t in allow and t not in deny]
    return [
        ("sandboxed", flag(bool(sb.get("sessionIsSandboxed")))),
        ("mode", sb.get("mode", "unknown")),
        ("backend", sb.get("backend", "unknown")),
        ("elevated", flag(bool((report.get("elevated") or {}).get("enabled")))),
        ("open_tools", ",".join(open_tools)),
        ("gateway_tools", ",".join(t for t in GATEWAY_TOOLS if t in allow and t not in deny)),
        ("write_tools", ",".join(t for t in WRITE_TOOLS if (t in allow or "*" in allow) and t not in deny)),
        ("shell_tools", ",".join(t for t in SHELL_TOOLS if (t in allow or "*" in allow) and t not in deny)),
        ("mounts", " ".join(f"{m.get('hostRoot')}:{m.get('containerRoot')}:{'rw' if m.get('writable') else 'ro'}"
                            for m in (sb.get("workspaceMounts") or []) if isinstance(m, dict))),
    ]


def agent(cfg, agent_id):
    """One agent's own tool settings from agents.entries.<id>, as (key, value) pairs."""
    entry = get(cfg, "agents", "entries", agent_id, default={})
    if not isinstance(entry, dict):
        entry = {}

    def joined(*keys):
        v = get(entry, *keys, default=[])
        return ",".join(map(str, v)) if isinstance(v, list) else ""
    return [
        ("configured", flag(agent_id in (get(cfg, "agents", "entries", default={}) or {}))),
        ("deny", joined("tools", "deny")),
        ("allow_agents", joined("subagents", "allowAgents")),
        ("delegate_to", joined("subagents", "delegateToolsTo")),
        # its own model, or "unset": then it shares the default model (and GPU) with main
        ("model", "unset" if get(entry, "model") is None else "set"),
        ("binds", joined("sandbox", "docker", "binds").replace(",", " ")),
        ("external_binds", flag(get(entry, "sandbox", "docker", "dangerouslyAllowExternalBindSources",
                                    default=False))),
        ("extra_paths", " ".join(
            str(p.get("path")) if isinstance(p, dict) else str(p)
            for p in (get(entry, "memory", "search", "extraPaths", default=[]) or []))),
    ]


def list_add(current, items):
    """current (a JSON list or nothing) with items appended, without duplicates.
    Items are strings or objects (e.g. memory extraPaths entries)."""
    out = []
    for i in (current if isinstance(current, list) else []) + list(items):
        if isinstance(i, (str, dict)) and i not in out:
            out.append(i)
    return out


def list_remove(current, items):
    """current (a JSON list or nothing) without items."""
    return [i for i in (current if isinstance(current, list) else []) if i not in items]


def parse_item(arg):
    """A list item from the command line: JSON if it looks like an object."""
    return json.loads(arg) if arg.startswith("{") else arg


def put_block(text, name, block):
    """text with block between safe-local-agents markers, replacing an old block
    (also one with the markers of the project's old name, safe-local-agent)."""
    begin = f"<!-- safe-local-agents:{name} begin (managed by install-sandbox.sh) -->"
    end = f"<!-- safe-local-agents:{name} end -->"
    new = f"{begin}\n{block.strip()}\n{end}\n"
    n = re.escape(name)
    pattern = re.compile(rf"<!-- safe-local-agents?:{n} begin.*?<!-- safe-local-agents?:{n} end -->\n?", re.S)
    if pattern.search(text):
        return pattern.sub(lambda _: new, text, count=1)
    sep = "" if not text or text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    return f"{text}{sep}{new}"


def also_allow(tools):
    """The list for tools.sandbox.tools.alsoAllow: plain tool names only."""
    for t in tools:
        if t == "*" or t.startswith("group:"):
            raise ValueError(f"SANDBOX_GATEWAY_TOOLS: list single tools, not '{t}'")
        if t in CONTROL_TOOLS:
            raise ValueError(f"SANDBOX_GATEWAY_TOOLS: '{t}' would let the agent change its setup from outside the sandbox")
        if not re.fullmatch(r"[a-z][a-z0-9_]*", t):
            raise ValueError(f"SANDBOX_GATEWAY_TOOLS: '{t}' is not a tool name")
    return list(tools)


def check_bind(bind, home, runtime_dir):
    """Raise ValueError unless bind is HOST:CONTAINER:ro|rw with a safe HOST."""
    parts = bind.split(":")
    if len(parts) != 3 or parts[2] not in ("ro", "rw") or not parts[0] or not parts[1]:
        raise ValueError(f"bind '{bind}' must look like /host/path:/path/in/sandbox:ro (or :rw)")
    host, container = parts[0], parts[1]
    if not os.path.isabs(host) or not os.path.isabs(container):
        raise ValueError(f"bind '{bind}': both paths must be absolute")
    if covers(container, PODMAN_INIT):
        raise ValueError(f"bind '{bind}' would hide Podman's init at {PODMAN_INIT}; mount it somewhere else")
    target = os.path.normpath(container)
    if target in OPENCLAW_TARGETS or any(covers(t, target) for t in OPENCLAW_TREES) \
            or any(covers(target, t) for t in OPENCLAW_TREES):
        raise ValueError(f"bind '{bind}' would hide a path OpenClaw mounts itself ({target})")
    real = os.path.realpath(host)
    if real == "/":
        raise ValueError(f"bind '{bind}' would expose the whole file system")
    for f in (os.path.join(home, ".openclaw"), runtime_dir):
        f = os.path.realpath(f)
        inside = real == f or real.startswith(f + os.sep)
        parent = f.startswith(real + os.sep)
        if inside or parent:
            raise ValueError(f"bind '{bind}' would expose {f} to the sandbox")


def sandbox_json(network, workspace, user, binds, home, runtime_dir):
    if network not in NETWORKS:
        raise ValueError(f"SANDBOX_NETWORK must be one of {', '.join(NETWORKS)}, not '{network}'")
    if workspace not in WORKSPACES:
        raise ValueError(f"SANDBOX_WORKSPACE must be one of {', '.join(WORKSPACES)}, not '{workspace}'")
    m = re.fullmatch(r"(\d+):(\d+)", user)
    if not m or "0" in (m.group(1), m.group(2)):
        raise ValueError(f"sandbox user must be a nonzero UID:GID, not '{user}'")
    for b in binds:
        check_bind(b, home, runtime_dir)
    return {
        "mode": "all",
        "backend": "podman",
        "workspaceAccess": workspace,
        "docker": {
            "image": IMAGE,
            "network": network,
            "readOnlyRoot": True,
            # not /run: Podman's init lives at /run/podman-init and must stay visible
            "tmpfs": list(TMPFS),
            "capDrop": ["ALL"],
            # rootless Podman maps this UID to the agent user (keep-id), so the
            # sandbox gets the agent's file permissions and no more
            "user": user,
            "env": {"HOME": "/tmp", "LANG": "C.UTF-8"},
            "binds": list(binds),
            # OpenClaw only mounts folders from outside a workspace with this
            # switch; it still blocks system, credential and socket paths
            "dangerouslyAllowExternalBindSources": bool(binds),
        },
        "browser": {"enabled": False},  # Podman can't sandbox the browser
    }


def find_key(obj, key):
    """The first value stored under key anywhere in nested dicts and lists."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        children = obj.values()
    elif isinstance(obj, list):
        children = obj
    else:
        return None
    for child in children:
        found = find_key(child, key)
        if found is not None:
            return found
    return None


def reply(envelope):
    """(status, tools, text) from `openclaw agent --json` output. The documented
    envelope has status, final, payloads and toolSummary at the top; the
    Gateway-backed command nests some of them (meta.toolSummary), so look
    anywhere."""
    status = find_key(envelope, "status")
    text = find_key(envelope, "final")
    if not isinstance(text, str) or not text:
        payloads = find_key(envelope, "payloads") or []
        text = "\n".join(p.get("text", "") for p in payloads if isinstance(p, dict))
    summary = find_key(envelope, "toolSummary") or {}
    tools = summary.get("tools", []) if isinstance(summary, dict) else []
    if not status:
        status = "error" if envelope.get("ok") is False or find_key(envelope, "error") else "unknown"
    return str(status), [str(t) for t in tools], text or ""


def reply_error(envelope):
    """OpenClaw's error message in an `openclaw agent --json` answer, if any."""
    err = find_key(envelope, "error")
    if isinstance(err, dict):
        err = err.get("message") or err.get("kind") or json.dumps(err)
    return " ".join(str(err).split()) if err else ""


def main(argv):
    args = argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd, args = args[0], args[1:]
    try:
        if cmd == "show":
            path = os.path.expanduser(args[0] if args else DEFAULT_PATH)
            with open(path, encoding="utf-8") as f:
                pairs = show(json.load(f))
        elif cmd == "explain":
            pairs = explain(json.load(sys.stdin))
        elif cmd == "plugins-json":
            print(json.dumps(args))
            return
        elif cmd == "also-allow-json":
            print(json.dumps(also_allow(args)))
            return
        elif cmd == "agent":
            if len(args) != 1:
                sys.exit("usage: agent ID")
            with open(os.path.expanduser(DEFAULT_PATH), encoding="utf-8") as f:
                pairs = agent(json.load(f), args[0])
        elif cmd == "agents":
            # stdin: `openclaw agents list --json`; prints "ID WORKSPACE default|-" per agent
            for a in json.load(sys.stdin):
                print(a.get("id", ""), a.get("workspace", ""), "default" if a.get("isDefault") else "-")
            return
        elif cmd == "reply":
            # stdin: `openclaw agent --json`; prints status=, tools=, then the text
            envelope = json.load(sys.stdin)
            status, tools, text = reply(envelope)
            print(f"status={status}")
            print(f"tools={','.join(tools)}")
            print(f"error={reply_error(envelope)}")
            print(text)
            return
        elif cmd in ("list-add", "list-remove"):
            # stdin: the current value (`openclaw config get ... --json`), may be empty
            raw = sys.stdin.read().strip()
            current = json.loads(raw) if raw.startswith("[") else []
            items = [parse_item(a) for a in args]
            print(json.dumps((list_add if cmd == "list-add" else list_remove)(current, items)))
            return
        elif cmd == "put-block":
            if len(args) != 2:
                sys.exit("usage: put-block FILE NAME < block")
            path, name = args
            if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
                sys.exit(f"bad block name: {name}")
            with open(path, encoding="utf-8") as f:
                text = f.read()
            new = put_block(text, name, sys.stdin.read())
            if new != text:
                tmp = f"{path}.sla-tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(new)
                os.replace(tmp, path)
                print(f"updated {path}")
            return
        elif cmd == "check-bind":
            home = os.path.expanduser("~")
            runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
            for b in args:
                check_bind(b, home, runtime_dir)
            return
        elif cmd == "sandbox-json":
            if len(args) < 3:
                sys.exit("usage: sandbox-json NETWORK WORKSPACE UID:GID [BIND...]")
            home = os.path.expanduser("~")
            runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
            print(json.dumps(sandbox_json(args[0], args[1], args[2], args[3:], home, runtime_dir)))
            return
        else:
            sys.exit(f"unknown command: {cmd}")
    except (ValueError, json.JSONDecodeError) as e:
        sys.exit(str(e))
    for k, v in pairs:
        print(f"{k}={v}")


if __name__ == "__main__":
    main(sys.argv)
