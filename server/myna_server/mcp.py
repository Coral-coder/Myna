"""A small MCP (Model Context Protocol) client, so Lumi can borrow tools from
any MCP server the user configures — filesystem, git, a database, a web service,
anything with an MCP server.

This speaks the stdio transport: each configured server is a subprocess, and we
exchange newline-delimited JSON-RPC 2.0 messages over its stdin/stdout. On start
we do the `initialize` handshake and fetch `tools/list`; Lumi's planner is then
offered those tools, and calling one routes to `tools/call`.

Configuring a server is itself the opt-in: the user adds its command in the
server's settings, which is the same trust as the shell tool (it runs a program
on their machine)."""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from typing import Any

PROTOCOL_VERSION = "2024-11-05"


class MCPError(Exception):
    pass


class MCPServer:
    """One MCP server subprocess and the JSON-RPC conversation with it."""

    def __init__(self, name: str, command: str, args: list[str] | None = None,
                 env: dict[str, str] | None = None, cwd: str | None = None) -> None:
        self.name = name
        self.command = command
        self.args = list(args or [])
        self.env = dict(env or {})
        self.cwd = cwd or None
        self.proc: subprocess.Popen | None = None
        self.tools: list[dict] = []
        self.error = ""
        self._id = 0
        self._lock = threading.Lock()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self) -> None:
        env = dict(os.environ)
        env.update(self.env)
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self.proc = subprocess.Popen(
            [self.command, *self.args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, env=env, cwd=self.cwd, bufsize=1, creationflags=flags,
        )
        self._request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "Lumi", "version": "1"},
        })
        self._notify("notifications/initialized")
        result = self._request("tools/list", {})
        self.tools = (result or {}).get("tools", []) or []

    def call(self, tool: str, arguments: dict | None = None) -> str:
        result = self._request("tools/call", {"name": tool, "arguments": arguments or {}})
        content = (result or {}).get("content") or []
        parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
        text = "\n".join(p for p in parts if p)
        if (result or {}).get("isError"):
            return f"(the tool reported an error)\n{text}"
        return text or json.dumps(result)[:3000]

    def stop(self) -> None:
        if self.proc is None:
            return
        try:
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        self.proc = None

    # -- JSON-RPC over stdio ----------------------------------------------------------

    def _send(self, message: dict) -> None:
        assert self.proc is not None and self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def _notify(self, method: str, params: dict | None = None) -> None:
        with self._lock:
            message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
            if params is not None:
                message["params"] = params
            self._send(message)

    def _request(self, method: str, params: dict | None = None, timeout: float = 25.0) -> dict | None:
        with self._lock:
            if self.proc is None or self.proc.stdout is None:
                raise MCPError("server not running")
            self._id += 1
            request_id = self._id
            message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
            if params is not None:
                message["params"] = params
            self._send(message)
            deadline = time.time() + timeout
            while time.time() < deadline:
                line = self.proc.stdout.readline()
                if not line:
                    raise MCPError(f"{self.name} closed the connection")
                try:
                    response = json.loads(line)
                except ValueError:
                    continue  # a log line or partial — skip
                if response.get("id") != request_id:
                    continue  # a notification or another message
                if "error" in response:
                    raise MCPError(str(response["error"].get("message", "MCP error")))
                return response.get("result")
            raise MCPError(f"{self.name} didn't answer {method} in time")


class MCPHub:
    """All configured MCP servers, started on first use."""

    def __init__(self, configs: list[dict]) -> None:
        self.configs = configs or []
        self.servers: dict[str, MCPServer] = {}
        self._started = False
        self._lock = threading.Lock()

    def ensure_started(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
            for config in self.configs:
                command = str(config.get("command") or "").strip()
                if not command:
                    continue
                name = str(config.get("name") or command)
                server = MCPServer(name, command, config.get("args"), config.get("env"), config.get("cwd"))
                try:
                    server.start()
                except Exception as error:
                    server.error = str(error)
                self.servers[name] = server

    def catalog(self) -> list[dict]:
        """Every available tool, as {server, name, description}."""
        self.ensure_started()
        out = []
        for server in self.servers.values():
            if not server.running:
                continue
            for tool in server.tools:
                out.append({"server": server.name, "name": tool.get("name", ""),
                            "description": (tool.get("description") or "")[:200]})
        return out

    def call(self, server: str, tool: str, arguments: dict | None = None) -> str:
        self.ensure_started()
        target = self.servers.get(server)
        if target is None:
            # If only one server, allow omitting its name.
            running = [s for s in self.servers.values() if s.running]
            if len(running) == 1:
                target = running[0]
            else:
                return f"No MCP server named {server!r}."
        if not target.running:
            return f"The MCP server {target.name!r} isn't running ({target.error or 'failed to start'})."
        try:
            return target.call(tool, arguments)[:4000]
        except Exception as error:
            return f"MCP call failed: {error}"

    def stop(self) -> None:
        for server in self.servers.values():
            server.stop()
        self.servers.clear()
        self._started = False
