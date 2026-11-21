"""Tests for lib/openclaw_config.py. Run: python3 -m unittest discover -s tests"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
SCRIPT = os.path.join(LIB, "openclaw_config.py")
sys.path.insert(0, LIB)
from openclaw_config import (  # noqa: E402
    PODMAN_INIT, agent, also_allow, check_bind, covers, explain, list_add, list_remove,
    parse_item, put_block, reply, reply_error, sandbox_json, show)

# Abridged `openclaw sandbox explain --json` from OpenClaw 2026.11.6 with
# mode "all": the effective tool policy is OpenClaw's default.
EXPLAIN = {
    "agentId": "main",
    "sandbox": {
        "mode": "all", "backend": "podman", "sessionIsSandboxed": True,
        "tools": {
            "allow": ["exec", "process", "read", "ls", "write", "edit", "apply_patch",
                      "sessions_list", "sessions_spawn", "session_status"],
            "deny": ["browser", "canvas", "computer", "nodes", "automations", "gateway", "telegram"],
        },
    },
    "elevated": {"enabled": False, "allowedByConfig": False},
}


class Show(unittest.TestCase):
    def test_defaults_for_an_empty_config(self):
        self.assertEqual(dict(show({})), {
            "tools_profile": "unset",
            "browser_enabled": "true",
            "elevated": "false",
            "plugins_allow": "",
            "sandbox_mode": "off",
            "sandbox_network": "none",
            "external_binds": "false",
            "web_search_provider": "unset",
            "searxng_url": "unset",
        })

    def test_hardened_config(self):
        # What install-openclaw.sh and install-searxng.sh write.
        cfg = {
            "tools": {"profile": "coding", "elevated": {"enabled": False},
                      "web": {"search": {"provider": "searxng"}}},
            "browser": {"enabled": False},
            "plugins": {"allow": ["document-extract", "ollama", "searxng"],
                        "entries": {"searxng": {"config": {"webSearch": {"baseUrl": "http://127.0.0.1:8888"}}}}},
            "agents": {"defaults": {"sandbox": {"mode": "all", "docker": {"network": "none"}}}},
        }
        s = dict(show(cfg))
        self.assertEqual(s["tools_profile"], "coding")
        self.assertEqual(s["browser_enabled"], "false")
        self.assertEqual(s["plugins_allow"], "document-extract,ollama,searxng")
        self.assertEqual(s["sandbox_mode"], "all")
        self.assertEqual(s["web_search_provider"], "searxng")
        self.assertEqual(s["searxng_url"], "http://127.0.0.1:8888")

    def test_tolerates_wrong_types(self):
        s = dict(show({"agents": "oops", "plugins": {"allow": "searxng"}, "tools": None}))
        self.assertEqual(s["sandbox_mode"], "off")
        self.assertEqual(s["plugins_allow"], "")
        self.assertEqual(s["tools_profile"], "unset")


class Explain(unittest.TestCase):
    def test_default_policy_keeps_control_tools_out(self):
        self.assertEqual(dict(explain(EXPLAIN)), {
            "sandboxed": "true", "mode": "all", "backend": "podman",
            "elevated": "false", "open_tools": "", "gateway_tools": "",
            "write_tools": "exec,process,write,edit,apply_patch",
            "shell_tools": "exec,process", "mounts": "",
        })

    def test_gateway_tools_from_also_allow(self):
        # tools.sandbox.tools.alsoAllow: ["web_search", "memory_search", "memory_get"]
        report = json.loads(json.dumps(EXPLAIN))
        report["sandbox"]["tools"]["allow"] += ["web_search", "memory_search", "memory_get"]
        s = dict(explain(report))
        self.assertEqual(s["gateway_tools"], "web_search,memory_search,memory_get")
        self.assertEqual(s["open_tools"], "")

    def test_control_tools_let_back_in(self):
        # tools.sandbox.tools.alsoAllow: ["gateway"] moves it from deny to allow
        report = json.loads(json.dumps(EXPLAIN))
        report["sandbox"]["tools"]["allow"] += ["gateway", "cron"]
        report["sandbox"]["tools"]["deny"].remove("gateway")
        self.assertEqual(dict(explain(report))["open_tools"], "gateway,cron")

    def test_deny_wins(self):
        report = json.loads(json.dumps(EXPLAIN))
        report["sandbox"]["tools"]["allow"].append("gateway")
        self.assertEqual(dict(explain(report))["open_tools"], "")

    def test_wildcard_allow(self):
        report = json.loads(json.dumps(EXPLAIN))
        report["sandbox"]["tools"]["allow"] = ["*"]
        report["sandbox"]["tools"]["deny"] = ["gateway"]
        self.assertEqual(dict(explain(report))["open_tools"], "cron,nodes,automations")

    def test_error_is_not_unsandboxed(self):
        # what 2026.11.6 prints for `sandbox explain --json` with two agents and no --agent
        err = {"ok": False, "error": {"type": "cli_error", "message":
               "Multiple agents are configured, but session agent resolution has no explicit owner."}}
        s = dict(explain(err))
        self.assertEqual(s["sandboxed"], "unknown")
        self.assertIn("Multiple agents", s["error"])

    def test_not_sandboxed_and_elevated(self):
        s = dict(explain({"sandbox": {"mode": "off", "sessionIsSandboxed": False},
                          "elevated": {"enabled": True}}))
        self.assertEqual(s["sandboxed"], "false")
        self.assertEqual(s["elevated"], "true")


class Agents(unittest.TestCase):
    # agents.entries as an earlier install-sandbox.sh left them (the reader
    # hand-off, which can't work in the sandbox and is now removed)
    CFG = {"agents": {"entries": {
        "main": {"workspace": "/w", "tools": {"deny": ["web_fetch"]},
                 "subagents": {"allowAgents": ["reader"], "delegateToolsTo": ["reader"]}},
        "reader": {"workspace": "/w-reader", "subagents": {"allowAgents": []},
                   "tools": {"deny": ["exec", "process", "write", "edit", "apply_patch"],
                             "sandbox": {"tools": {"allow": ["read", "ls", "web_search", "web_fetch"]}}}},
    }}}

    def test_main(self):
        self.assertEqual(dict(agent(self.CFG, "main")), {
            "configured": "true", "deny": "web_fetch", "allow_agents": "reader",
            "delegate_to": "reader", "model": "unset", "binds": "", "external_binds": "false",
            "extra_paths": ""})

    def test_reader_and_missing(self):
        self.assertEqual(dict(agent(self.CFG, "reader"))["deny"], "exec,process,write,edit,apply_patch")
        self.assertEqual(dict(agent(self.CFG, "nobody"))["configured"], "false")
        self.assertEqual(dict(agent({}, "main"))["deny"], "")

    def test_reader_sandbox_has_no_write_tools(self):
        # abridged `sandbox explain --agent reader --json` for the config above
        report = {"sandbox": {"mode": "all", "sessionIsSandboxed": True, "tools": {
            "allow": ["read", "ls", "web_search", "web_fetch", "memory_search", "memory_get", "view_image"],
            "deny": EXPLAIN["sandbox"]["tools"]["deny"]}}}
        s = dict(explain(report))
        self.assertEqual(s["write_tools"], "")
        self.assertEqual(s["open_tools"], "")
        self.assertEqual(dict(explain(EXPLAIN))["write_tools"], "exec,process,write,edit,apply_patch")


class Researcher(unittest.TestCase):
    # what install-sandbox.sh sets, checked against OpenClaw 2026.11.6
    CFG = {"agents": {"entries": {
        "main": {"tools": {"deny": ["web_fetch"]},
                 "subagents": {"allowAgents": [], "delegateToolsTo": []},
                 "sandbox": {"docker": {"binds": ["/home/mrdata/research:/research:ro"],
                                        "dangerouslyAllowExternalBindSources": True}},
                 "memory": {"search": {"extraPaths": [
                     {"path": "/home/mrdata/research", "pattern": "**/*.md"}]}}},
        "researcher": {"workspace": "/home/mrdata/.openclaw/workspace-researcher",
                       "sandbox": {"workspaceAccess": "none", "docker": {
                           "binds": ["/home/mrdata/research:/workspace/results:rw"],
                           "dangerouslyAllowExternalBindSources": True}},
                       "tools": {"deny": ["exec", "process", "apply_patch"],
                                 "sandbox": {"tools": {"allow": ["read", "ls", "write", "edit",
                                                                 "web_search", "web_fetch"]}}}},
    }}}

    def test_main_fields(self):
        m = dict(agent(self.CFG, "main"))
        self.assertEqual(m["binds"], "/home/mrdata/research:/research:ro")
        self.assertEqual(m["external_binds"], "true")
        self.assertEqual(m["extra_paths"], "/home/mrdata/research")
        self.assertEqual(m["delegate_to"], "")

    def test_researcher_explain(self):
        # abridged `sandbox explain --agent researcher --json`
        report = {"sandbox": {"mode": "all", "sessionIsSandboxed": True,
                  # workspaceAccess none: a scratch workspace, plus the results folder
                  "workspaceMounts": [
                      {"hostRoot": "/home/mrdata/.openclaw/sandboxes/workspace-6820e9cd",
                       "containerRoot": "/workspace", "writable": True},
                      {"hostRoot": "/home/mrdata/research", "containerRoot": "/workspace/results",
                       "writable": True}],
                  "tools": {"allow": ["read", "ls", "write", "edit", "web_search", "web_fetch",
                                      "memory_search", "memory_get", "view_image"],
                            "deny": EXPLAIN["sandbox"]["tools"]["deny"]}}}
        s = dict(explain(report))
        self.assertEqual(s["shell_tools"], "")
        self.assertEqual(s["write_tools"], "write,edit")
        self.assertIn("web_fetch", s["gateway_tools"])
        self.assertEqual(s["mounts"], "/home/mrdata/.openclaw/sandboxes/workspace-6820e9cd:/workspace:rw "
                                      "/home/mrdata/research:/workspace/results:rw")
        # its own workspace (AGENTS.md) is not among them
        self.assertNotIn("/home/mrdata/.openclaw/workspace-researcher:", s["mounts"])
        self.assertEqual(dict(agent(self.CFG, "researcher"))["binds"],
                         "/home/mrdata/research:/workspace/results:rw")

    def test_research_bind_is_allowed_but_not_inside_openclaw(self):
        check_bind("/home/mrdata/research:/research:ro", "/home/mrdata", "/run/user/961")
        with self.assertRaises(ValueError):
            check_bind("/home/mrdata/.openclaw/workspace-reader:/research:ro", "/home/mrdata", "/run/user/961")


class Reply(unittest.TestCase):
    def test_documented_envelope(self):
        # the `--json` example in OpenClaw 2026.11.6's cli/agent.md
        env = {"ok": True, "status": "ok", "final": "The focused tests pass.",
               "payloads": [{"text": "The focused tests pass."}],
               "toolSummary": {"calls": 2, "tools": ["read", "write"], "totalToolTimeMs": 48},
               "model": "gpt-6-astra", "sessionId": "019..."}
        self.assertEqual(reply(env), ("ok", ["read", "write"], "The focused tests pass."))

    def test_nested_gateway_shape(self):
        # "the tool summary remains at meta.toolSummary" for `openclaw agent --json`
        env = {"result": {"status": "ok", "payloads": [{"text": "a"}, {"text": "b"}],
                          "meta": {"toolSummary": {"tools": ["web_search"]}}}}
        self.assertEqual(reply(env), ("ok", ["web_search"], "a\nb"))

    def test_failure(self):
        env = {"ok": False, "status": "error", "error": {"message": "boom", "kind": "x"}}
        self.assertEqual(reply(env), ("error", [], ""))
        self.assertEqual(reply_error(env), "boom")

    def test_error_without_status_is_an_error(self):
        # a turn that never ran must not look like "nothing happened"
        env = {"ok": False, "error": {"message": "unable to start container"}}
        self.assertEqual(reply(env)[0], "error")
        self.assertEqual(reply_error({"result": {"error": "plain text"}}), "plain text")
        self.assertEqual(reply({"weird": 1})[0], "unknown")


class ListAdd(unittest.TestCase):
    def test_adds_without_duplicates(self):
        self.assertEqual(list_add(["exec"], ["web_fetch", "exec"]), ["exec", "web_fetch"])
        self.assertEqual(list_add(None, ["reader"]), ["reader"])
        self.assertEqual(list_add("oops", ["reader"]), ["reader"])
        self.assertEqual(list_add(["web_fetch", "web_fetch", 3], ["web_fetch"]), ["web_fetch"])

    def test_objects(self):
        entry = {"path": "/r/results", "pattern": "**/*.md"}
        self.assertEqual(list_add([entry], [parse_item('{"path": "/r/results", "pattern": "**/*.md"}')]), [entry])
        self.assertEqual(parse_item("reader"), "reader")

    def test_remove(self):
        self.assertEqual(list_remove(["reader", "other"], ["reader"]), ["other"])
        self.assertEqual(list_remove(None, ["reader"]), [])


class PutBlock(unittest.TestCase):
    def test_appends_then_replaces(self):
        text = "# AGENTS.md\n\nBe helpful.\n"
        once = put_block(text, "security", "## Rules v1")
        self.assertTrue(once.startswith(text))
        self.assertIn("## Rules v1", once)
        twice = put_block(once, "security", "## Rules v2")
        self.assertNotIn("v1", twice)
        self.assertEqual(twice.count("safe-local-agents:security begin"), 1)
        self.assertEqual(put_block(twice, "security", "## Rules v2"), twice)  # idempotent

    def test_keeps_text_after_the_block(self):
        text = put_block("intro\n", "security", "rules") + "\nuser notes\n"
        self.assertTrue(put_block(text, "security", "new rules").endswith("\nuser notes\n"))

    def test_empty_file(self):
        self.assertTrue(put_block("", "security", "rules").startswith("<!-- safe-local-agents:security begin"))

    def test_replaces_block_with_the_old_project_name(self):
        old = ("intro\n<!-- safe-local-agent:security begin (managed by install-sandbox.sh) -->\n"
               "old rules\n<!-- safe-local-agent:security end -->\nafter\n")
        new = put_block(old, "security", "new rules")
        self.assertNotIn("old rules", new)
        self.assertNotIn("safe-local-agent:", new)
        self.assertEqual(new.count("safe-local-agents:security begin"), 1)
        self.assertTrue(new.startswith("intro\n") and new.endswith("after\n"))


class AlsoAllow(unittest.TestCase):
    def test_plain_tools(self):
        self.assertEqual(also_allow(["web_search", "memory_get"]), ["web_search", "memory_get"])
        self.assertEqual(also_allow([]), [])

    def test_rejects_wildcards_groups_and_control_tools(self):
        for t in ("*", "group:web", "group:runtime", "gateway", "cron", "nodes", "automations", "Web Search", ""):
            with self.assertRaises(ValueError, msg=t):
                also_allow([t])


class SandboxJson(unittest.TestCase):
    HOME = "/home/agent"
    RUN = "/run/user/961"

    def build(self, *args, binds=()):
        return sandbox_json(*args, list(binds), self.HOME, self.RUN)

    def test_shape(self):
        sb = self.build("none", "rw", "961:961", binds=["/srv/agent-share:/share:ro"])
        self.assertEqual(sb["mode"], "all")
        self.assertEqual(sb["backend"], "podman")
        self.assertEqual(sb["workspaceAccess"], "rw")
        d = sb["docker"]
        self.assertEqual(d["network"], "none")
        self.assertEqual(d["user"], "961:961")
        self.assertTrue(d["readOnlyRoot"])
        self.assertEqual(d["capDrop"], ["ALL"])
        self.assertEqual(d["binds"], ["/srv/agent-share:/share:ro"])
        self.assertIn("/tmp", d["tmpfs"])
        self.assertEqual(d["env"]["HOME"], "/tmp")
        self.assertFalse(sb["browser"]["enabled"])

    def test_nothing_covers_podman_init(self):
        # OpenClaw refuses to start a Podman sandbox if a tmpfs or bind hides
        # /run/podman-init ("INVALID_CONFIG"), which the first version did.
        d = self.build("none", "rw", "961:961", binds=["/srv/a:/share:ro"])["docker"]
        mounts = d["tmpfs"] + [b.split(":")[1] for b in d["binds"]]
        for m in mounts:
            self.assertFalse(covers(m, PODMAN_INIT), m)

    def test_empty_binds_is_a_list(self):
        # --merge replaces lists, so [] removes binds set earlier
        d = self.build("none", "rw", "961:961")["docker"]
        self.assertEqual(d["binds"], [])
        self.assertFalse(d["dangerouslyAllowExternalBindSources"])

    def test_external_binds_switch_only_with_binds(self):
        # OpenClaw refuses bind sources outside the workspace without it
        d = self.build("none", "rw", "961:961", binds=["/srv/agent-share:/share:ro"])["docker"]
        self.assertTrue(d["dangerouslyAllowExternalBindSources"])

    def test_rejects_bad_values(self):
        for args in (("host", "rw", "961:961"), ("none", "all", "961:961"),
                     ("none", "rw", "0:0"), ("none", "rw", "961"), ("none", "rw", "mrdata:mrdata")):
            with self.assertRaises(ValueError, msg=args):
                self.build(*args)


class CheckBind(unittest.TestCase):
    HOME = "/home/agent"
    RUN = "/run/user/961"

    def ok(self, bind):
        check_bind(bind, self.HOME, self.RUN)

    def bad(self, bind):
        with self.assertRaises(ValueError, msg=bind):
            check_bind(bind, self.HOME, self.RUN)

    def test_accepts_shared_folders(self):
        self.ok("/srv/agent-share:/share:ro")
        self.ok("/srv/agent-share/out:/out:rw")
        self.ok("/home/agent/.openclaw-notes:/notes:ro")  # a sibling, not the state dir

    def test_rejects_malformed(self):
        for b in ("/srv/a", "/srv/a:/a", "/srv/a:/a:rx", "srv/a:/a:ro", "/srv/a:a:ro", ":/a:ro"):
            self.bad(b)

    def test_rejects_targets_over_openclaw_mounts(self):
        for target in ("/workspace", "/workspace/", "/agent", "/workspace/skills",
                       "/workspace/skills/x", "/workspace/.agents", "/workspace/.openclaw/sandbox-skills"):
            self.bad(f"/srv/a:{target}:ro")
        self.ok("/srv/a:/workspace/results:rw")   # the researcher's results
        self.ok("/srv/a:/workspace-data:ro")

    def test_rejects_targets_over_podman_init(self):
        for target in ("/", "/run", "/run/", "/run/podman-init"):
            self.bad(f"/srv/a:{target}:ro")
        self.ok("/srv/a:/runner:ro")  # only a prefix of the name, not a parent
        self.ok("/srv/a:/run-data:ro")

    def test_rejects_state_runtime_dir_and_their_parents(self):
        for b in ("/home/agent/.openclaw:/s:ro", "/home/agent/.openclaw/workspace:/w:rw",
                  "/home/agent:/h:ro", "/home:/h:ro", "/:/root:ro",
                  "/run/user/961:/r:ro", "/run/user/961/podman:/p:rw", "/run:/r:ro"):
            self.bad(b)


class Script(unittest.TestCase):
    def run_script(self, *args, stdin=""):
        return subprocess.run([sys.executable, SCRIPT, *args], input=stdin,
                              capture_output=True, text=True)

    def test_show_reads_a_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "openclaw.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"tools": {"profile": "coding"}}, f)
            r = self.run_script("show", path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("tools_profile=coding\n", r.stdout)

    def test_explain_from_stdin(self):
        r = self.run_script("explain", stdin=json.dumps(EXPLAIN))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sandboxed=true\n", r.stdout)

    def test_plugins_json(self):
        r = self.run_script("plugins-json", "document-extract", "ollama")
        self.assertEqual(json.loads(r.stdout), ["document-extract", "ollama"])

    def test_sandbox_json_rejects_unsafe_bind(self):
        r = self.run_script("sandbox-json", "none", "rw", "961:961", "/:/root:ro")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("whole file system", r.stderr)


if __name__ == "__main__":
    unittest.main()
