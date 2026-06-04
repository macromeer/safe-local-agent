from __future__ import annotations

import argparse
import contextlib
import sys
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from io import TextIOWrapper
from typing import Any, TypedDict
from urllib.request import urlopen

import anyio
from pydantic import AnyHttpUrl, AnyUrl, BaseModel, Field

from mcp import types
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import Context, FastMCP
from mcp.server.lowlevel import NotificationOptions, Server
from mcp.server.models import InitializationOptions
from mcp.server.session import ServerSession
from mcp.server.stdio import stdio_server


class _FilteredAsyncFile:
    def __init__(self, inner: anyio.AsyncFile) -> None:
        self._inner = inner

    def __aiter__(self):
        return self._aiter()

    async def _aiter(self):
        async for line in self._inner:
            if line.strip():
                yield line

    def __getattr__(self, name: str):
        return getattr(self._inner, name)


class WeatherData(BaseModel):
    temperature: float = Field(description="Temperature in Celsius")
    humidity: float = Field(description="Humidity percentage")
    condition: str
    wind_speed: float


class LocationInfo(TypedDict):
    latitude: float
    longitude: float
    name: str


class BookingPreferences(BaseModel):
    checkAlternative: bool = Field(description="Would you like to check another date?")
    alternativeDate: str = Field(default="2026-06-05", description="Alternative date (YYYY-MM-DD)")


class LocalTokenVerifier(TokenVerifier):
    async def verify_token(self, token: str) -> AccessToken | None:
        if token != "demo-token":
            return None
        return AccessToken(
            token=token,
            client_id="local-demo-client",
            scopes=["user"],
            subject="demo-user",
            claims={"iss": "local-demo"},
        )


def build_quickstart_server() -> FastMCP:
    mcp = FastMCP("Demo")

    @mcp.tool()
    def add(a: int, b: int) -> int:
        return a + b

    @mcp.resource("greeting://{name}")
    def get_greeting(name: str) -> str:
        return f"Hello, {name}!"

    @mcp.prompt(title="Greet User")
    def greet_user(name: str, style: str = "friendly") -> str:
        styles = {
            "friendly": "Please write a warm, friendly greeting",
            "formal": "Please write a formal, professional greeting",
            "casual": "Please write a casual, relaxed greeting",
        }
        return f"{styles.get(style, styles['friendly'])} for someone named {name}."

    return mcp


def build_tool_server() -> FastMCP:
    mcp = FastMCP("Tool Example")

    @mcp.tool()
    def sum_numbers(a: int, b: int) -> int:
        return a + b

    @mcp.tool()
    def get_weather(city: str, unit: str = "celsius") -> str:
        return f"Weather in {city}: 22 degrees {unit}"

    @mcp.tool()
    def fetch_title(url: str) -> str:
        with urlopen(url, timeout=10) as response:
            body = response.read().decode("utf-8", errors="replace")
        start = body.lower().find("<title>")
        end = body.lower().find("</title>")
        if start != -1 and end != -1 and end > start:
            return body[start + 7 : end].strip()
        return "No title found"

    return mcp


def build_resource_server() -> FastMCP:
    mcp = FastMCP("Resource Example")

    @mcp.resource("file://documents/{name}")
    def read_document(name: str) -> str:
        return f"Content of {name}"

    @mcp.resource("config://settings")
    def get_settings() -> str:
        return """{\n  \"theme\": \"dark\",\n  \"language\": \"en\",\n  \"debug\": false\n}"""

    return mcp


def build_prompt_server() -> FastMCP:
    mcp = FastMCP("Prompt Example")

    @mcp.prompt(title="Code Review")
    def review_code(code: str) -> str:
        return f"Please review this code:\n\n{code}"

    @mcp.prompt(title="Debug Assistant")
    def debug_error(error: str) -> list[types.PromptMessage]:
        return [
            types.PromptMessage(role="user", content=types.TextContent(type="text", text="I'm seeing this error:")),
            types.PromptMessage(role="user", content=types.TextContent(type="text", text=error)),
            types.PromptMessage(
                role="assistant",
                content=types.TextContent(type="text", text="I'll help debug that. What have you tried so far?"),
            ),
        ]

    @mcp.completion()
    async def complete_prompt_argument(ref: Any, argument: Any, context: Any) -> types.Completion:
        if getattr(ref, "type", None) == "ref/prompt" and getattr(argument, "name", None) == "style":
            return types.Completion(values=["friendly", "formal", "casual"])
        return types.Completion(values=[])

    return mcp


def build_direct_execution_server() -> FastMCP:
    mcp = FastMCP("My App")

    @mcp.tool()
    def hello(name: str = "World") -> str:
        return f"Hello, {name}!"

    return mcp


def build_structured_output_server() -> FastMCP:
    mcp = FastMCP("Structured Output Example")

    @mcp.tool()
    def get_weather(city: str) -> WeatherData:
        return WeatherData(temperature=22.5, humidity=45.0, condition="sunny", wind_speed=5.2)

    @mcp.tool()
    def get_location(address: str) -> LocationInfo:
        return LocationInfo(latitude=51.5074, longitude=-0.1278, name=f"{address}, London")

    @mcp.tool()
    def get_statistics(data_type: str) -> dict[str, float]:
        return {"mean": 42.5, "median": 40.0, "std_dev": 5.2}

    @mcp.tool()
    def get_user(user_id: str) -> dict[str, str | int]:
        return {"name": "Alice", "age": 30, "email": "alice@example.com", "user_id": user_id}

    @mcp.tool()
    def list_cities() -> list[str]:
        return ["London", "Paris", "Tokyo"]

    @mcp.tool()
    def get_temperature(city: str) -> float:
        return 22.5

    return mcp


def build_lifespan_server() -> FastMCP:
    class Database:
        @classmethod
        async def connect(cls) -> Database:
            return cls()

        async def disconnect(self) -> None:
            return None

        def query(self) -> str:
            return "Query result"

    @contextlib.asynccontextmanager
    async def app_lifespan(server: FastMCP) -> AsyncIterator[dict[str, Any]]:
        db = await Database.connect()
        try:
            yield {"db": db}
        finally:
            await db.disconnect()

    mcp = FastMCP("My App", lifespan=app_lifespan)

    @mcp.tool()
    def query_db(ctx: Context[ServerSession, dict[str, Any]]) -> str:
        return ctx.request_context.lifespan_context["db"].query()

    return mcp


def build_progress_server() -> FastMCP:
    mcp = FastMCP("Progress Example")

    @mcp.tool()
    async def long_running_task(task_name: str, ctx: Context[ServerSession, None], steps: int = 5) -> str:
        await ctx.info(f"Starting: {task_name}")
        for step in range(steps):
            progress = (step + 1) / steps
            await ctx.report_progress(progress=progress, total=1.0, message=f"Step {step + 1}/{steps}")
            await ctx.debug(f"Completed step {step + 1}")
        return f"Task '{task_name}' completed"

    return mcp


def build_notifications_server() -> FastMCP:
    mcp = FastMCP("Notifications Example")

    @mcp.tool()
    async def process_data(data: str, ctx: Context[ServerSession, None]) -> str:
        await ctx.debug(f"Debug: Processing '{data}'")
        await ctx.info("Info: Starting processing")
        await ctx.warning("Warning: This is experimental")
        await ctx.error("Error: This is just a demo")
        await ctx.session.send_resource_list_changed()
        return f"Processed: {data}"

    return mcp


def build_sampling_server() -> FastMCP:
    mcp = FastMCP("Sampling Example")

    @mcp.tool()
    async def generate_poem(topic: str, ctx: Context[ServerSession, None]) -> str:
        prompt = f"Write a short poem about {topic}"
        result = await ctx.session.create_message(
            messages=[types.SamplingMessage(role="user", content=types.TextContent(type="text", text=prompt))],
            max_tokens=100,
        )
        if result.content.type == "text":
            return result.content.text
        return str(result.content)

    return mcp


def build_elicitation_server() -> FastMCP:
    mcp = FastMCP("Elicitation Example")

    @mcp.tool()
    async def book_table(date: str, time: str, party_size: int, ctx: Context[ServerSession, None]) -> str:
        if date == "2026-12-25":
            result = await ctx.elicit(
                message=f"No tables available for {party_size} on {date}. Would you like to try another date?",
                schema=BookingPreferences,
            )
            if result.action == "accept" and result.data:
                if result.data.checkAlternative:
                    return f"[SUCCESS] Booked for {result.data.alternativeDate}"
                return "[CANCELLED] No booking made"
            return "[CANCELLED] Booking cancelled"
        return f"[SUCCESS] Booked for {date} at {time}"

    return mcp


def build_completion_server() -> FastMCP:
    mcp = FastMCP("Completion Example")

    @mcp.resource("repo://{owner}/{repo}")
    def repo_resource(owner: str, repo: str) -> str:
        return f"Repository: {owner}/{repo}"

    @mcp.prompt(title="Style Guide")
    def style_guide(style: str = "friendly") -> str:
        return f"Use a {style} tone."

    @mcp.completion()
    async def complete(ref: Any, argument: Any, context: Any) -> types.Completion:
        if getattr(ref, "type", None) == "ref/resource" and getattr(argument, "name", None) == "repo":
            return types.Completion(values=["python-sdk", "servers", "specification"])
        if getattr(ref, "type", None) == "ref/prompt" and getattr(argument, "name", None) == "style":
            return types.Completion(values=["friendly", "formal", "casual"])
        return types.Completion(values=[])

    return mcp


def build_streamable_server(stateless: bool = False) -> FastMCP:
    mcp = FastMCP("StatelessServer" if stateless else "Streamable Server", json_response=True, stateless_http=stateless)

    @mcp.tool()
    def greet(name: str = "World") -> str:
        return f"Hello, {name}!"

    return mcp


def build_streamable_http_basic_mounting_app() -> Any:
    from starlette.applications import Starlette
    from starlette.routing import Mount

    mcp = FastMCP("My App", json_response=True)

    @mcp.tool()
    def hello() -> str:
        return "Hello from MCP!"

    @contextlib.asynccontextmanager
    async def lifespan(app: Any):
        async with mcp.session_manager.run():
            yield

    return Starlette(routes=[Mount("/", app=mcp.streamable_http_app())], lifespan=lifespan)


def build_streamable_http_host_mounting_app() -> Any:
    from starlette.applications import Starlette
    from starlette.routing import Host

    mcp = FastMCP("MCP Host App", json_response=True)

    @mcp.tool()
    def domain_info() -> str:
        return "This is served from mcp.acme.corp"

    @contextlib.asynccontextmanager
    async def lifespan(app: Any):
        async with mcp.session_manager.run():
            yield

    return Starlette(routes=[Host("mcp.acme.corp", app=mcp.streamable_http_app())], lifespan=lifespan)


def build_streamable_http_multiple_servers_app() -> Any:
    from starlette.applications import Starlette
    from starlette.routing import Mount

    api_mcp = FastMCP("API Server", json_response=True)
    chat_mcp = FastMCP("Chat Server", json_response=True)

    @api_mcp.tool()
    def api_status() -> str:
        return "API is running"

    @chat_mcp.tool()
    def send_message(message: str) -> str:
        return f"Message sent: {message}"

    api_mcp.settings.streamable_http_path = "/"
    chat_mcp.settings.streamable_http_path = "/"

    @contextlib.asynccontextmanager
    async def lifespan(app: Any):
        async with contextlib.AsyncExitStack() as stack:
            await stack.enter_async_context(api_mcp.session_manager.run())
            await stack.enter_async_context(chat_mcp.session_manager.run())
            yield

    return Starlette(
        routes=[
            Mount("/api", app=api_mcp.streamable_http_app()),
            Mount("/chat", app=chat_mcp.streamable_http_app()),
        ],
        lifespan=lifespan,
    )


def build_streamable_http_path_config_app() -> Any:
    from starlette.applications import Starlette
    from starlette.routing import Mount

    mcp = FastMCP("My Server", json_response=True, streamable_http_path="/")

    @mcp.tool()
    def process_data(data: str) -> str:
        return f"Processed: {data}"

    @contextlib.asynccontextmanager
    async def lifespan(app: Any):
        async with mcp.session_manager.run():
            yield

    return Starlette(routes=[Mount("/process", app=mcp.streamable_http_app())], lifespan=lifespan)


def build_oauth_server() -> FastMCP:
    auth = AuthSettings(
        issuer_url=AnyHttpUrl("https://auth.local.example"),
        resource_server_url=AnyHttpUrl("http://localhost:8000"),
        required_scopes=["user"],
    )

    mcp = FastMCP("Weather Service", json_response=True, token_verifier=LocalTokenVerifier(), auth=auth)

    @mcp.tool()
    async def get_weather(city: str = "London") -> dict[str, str]:
        return {
            "city": city,
            "temperature": "22",
            "condition": "Partly cloudy",
            "humidity": "65%",
        }

    return mcp


def build_everything_server() -> FastMCP:
    mcp = FastMCP("Everything Server", json_response=True, stateless_http=True)

    @mcp.tool()
    def add(a: int, b: int) -> int:
        return a + b

    @mcp.tool()
    def echo(text: str) -> str:
        return f"Echo: {text}"

    @mcp.resource("about://server")
    def about() -> str:
        return "This is the everything server."

    @mcp.prompt(title="Review")
    def review_code(code: str) -> str:
        return f"Please review this code:\n\n{code}"

    @mcp.completion()
    async def complete(ref: Any, argument: Any, context: Any) -> types.Completion:
        if getattr(argument, "name", None) == "style":
            return types.Completion(values=["friendly", "formal", "casual"])
        return types.Completion(values=["alpha", "beta", "gamma"])

    @mcp.tool()
    async def long_running_task(task_name: str, ctx: Context[ServerSession, None], steps: int = 3) -> str:
        for step in range(steps):
            await ctx.report_progress(progress=(step + 1) / steps, total=1.0, message=f"Step {step + 1}/{steps}")
        return f"{task_name} complete"

    return mcp


def build_lowlevel_structured_output_server() -> Server:
    server = Server("structured-output-example")

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return [
            types.Tool(
                name="get_weather",
                description="Get current weather for a city",
                inputSchema={
                    "type": "object",
                    "properties": {"city": {"type": "string", "description": "City name"}},
                    "required": ["city"],
                },
                outputSchema={
                    "type": "object",
                    "properties": {
                        "temperature": {"type": "number", "description": "Temperature in Celsius"},
                        "condition": {"type": "string", "description": "Weather condition"},
                        "humidity": {"type": "number", "description": "Humidity percentage"},
                        "city": {"type": "string", "description": "City name"},
                    },
                    "required": ["temperature", "condition", "humidity", "city"],
                },
            )
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name != "get_weather":
            raise ValueError(f"Unknown tool: {name}")
        city = arguments["city"]
        return {
            "temperature": 22.5,
            "condition": "partly cloudy",
            "humidity": 65,
            "city": city,
        }

    return server


def build_lowlevel_pagination_server() -> Server:
    server = Server("paginated-server")
    items = [f"Item {index}" for index in range(1, 101)]

    @server.list_resources()
    async def list_resources_paginated(request: types.ListResourcesRequest) -> types.ListResourcesResult:
        page_size = 10
        cursor = request.params.cursor if request.params is not None else None
        start = 0 if cursor is None else int(cursor)
        end = start + page_size
        page_items = [
            types.Resource(uri=AnyUrl(f"resource://items/{item}"), name=item, description=f"Description for {item}")
            for item in items[start:end]
        ]
        next_cursor = str(end) if end < len(items) else None
        return types.ListResourcesResult(resources=page_items, nextCursor=next_cursor)

    return server


def build_sse_polling_demo_server() -> FastMCP:
    mcp = FastMCP("SSE Polling Demo")

    @mcp.tool()
    async def long_running_task(task_name: str, ctx: Context[ServerSession, None], steps: int = 5) -> str:
        for step in range(steps):
            await ctx.report_progress(progress=(step + 1) / steps, total=1.0, message=f"Step {step + 1}/{steps}")
        return f"Completed {task_name}"

    return mcp


def _run_asgi_app(app: Any) -> None:
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)


def _run_fastmcp_stdio(mcp: FastMCP) -> None:
    async def _run() -> None:
        raw_stdin = anyio.wrap_file(TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace"))
        filtered_stdin = _FilteredAsyncFile(raw_stdin)
        async with stdio_server(stdin=filtered_stdin) as (read_stream, write_stream):
            await mcp._mcp_server.run(read_stream, write_stream, mcp._mcp_server.create_initialization_options())

    anyio.run(_run)


def _run_lowlevel_stdio(server: Server) -> None:
    async def _run() -> None:
        raw_stdin = anyio.wrap_file(TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace"))
        filtered_stdin = _FilteredAsyncFile(raw_stdin)
        async with stdio_server(stdin=filtered_stdin) as (read_stream, write_stream):
            await server.run(
                read_stream,
                write_stream,
                InitializationOptions(
                    server_name=server.name,
                    server_version="0.1.0",
                    capabilities=server.get_capabilities(
                        notification_options=NotificationOptions(),
                        experimental_capabilities={},
                    ),
                ),
            )

    anyio.run(_run)


@dataclass(frozen=True)
class ServerSpec:
    builder: Callable[[], Any]
    kind: str = "fastmcp"
    transport: str = "stdio"


SERVER_SPECS: dict[str, ServerSpec] = {
    "fastmcp_quickstart": ServerSpec(build_quickstart_server),
    "basic_tool": ServerSpec(build_tool_server),
    "simple_tool": ServerSpec(build_tool_server),
    "basic_resource": ServerSpec(build_resource_server),
    "simple_resource": ServerSpec(build_resource_server),
    "basic_prompt": ServerSpec(build_prompt_server),
    "simple_prompt": ServerSpec(build_prompt_server),
    "direct_execution": ServerSpec(build_direct_execution_server),
    "structured_output": ServerSpec(build_structured_output_server),
    "lifespan_example": ServerSpec(build_lifespan_server),
    "tool_progress": ServerSpec(build_progress_server),
    "notifications": ServerSpec(build_notifications_server),
    "sampling": ServerSpec(build_sampling_server),
    "elicitation": ServerSpec(build_elicitation_server),
    "completion": ServerSpec(build_completion_server),
    "streamable_config": ServerSpec(lambda: build_streamable_server(False), transport="streamable-http"),
    "simple_streamablehttp": ServerSpec(lambda: build_streamable_server(False), transport="streamable-http"),
    "simple_streamablehttp_stateless": ServerSpec(lambda: build_streamable_server(True), transport="streamable-http"),
    "streamable_http_basic_mounting": ServerSpec(build_streamable_http_basic_mounting_app, kind="asgi"),
    "streamable_http_host_mounting": ServerSpec(build_streamable_http_host_mounting_app, kind="asgi"),
    "streamable_http_multiple_servers": ServerSpec(build_streamable_http_multiple_servers_app, kind="asgi"),
    "streamable_http_path_config": ServerSpec(build_streamable_http_path_config_app, kind="asgi"),
    "oauth_server": ServerSpec(build_oauth_server, transport="streamable-http"),
    "simple_auth": ServerSpec(build_oauth_server, transport="streamable-http"),
    "everything_server": ServerSpec(build_everything_server, transport="streamable-http"),
    "simple_pagination": ServerSpec(build_lowlevel_pagination_server),
    "pagination_example": ServerSpec(build_lowlevel_pagination_server),
    "structured_output_lowlevel": ServerSpec(build_lowlevel_structured_output_server),
    "sse_polling_demo": ServerSpec(build_sse_polling_demo_server, transport="sse"),
}


def list_server_names() -> list[str]:
    return sorted(SERVER_SPECS)


def run_server(name: str) -> None:
    if name not in SERVER_SPECS:
        available = ", ".join(list_server_names())
        raise SystemExit(f"Unknown built-in server '{name}'. Available servers: {available}")

    spec = SERVER_SPECS[name]
    server = spec.builder()
    if spec.kind == "asgi":
        _run_asgi_app(server)
        return
    if isinstance(server, FastMCP):
        if spec.transport == "stdio":
            _run_fastmcp_stdio(server)
            return
        server.run(transport=spec.transport)
        return

    if isinstance(server, Server):
        _run_lowlevel_stdio(server)
        return

    raise TypeError(f"Unsupported server type: {type(server)!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run one of the upstream MCP SDK built-in servers.")
    parser.add_argument("server", nargs="?", default="fastmcp_quickstart", choices=list_server_names())
    args = parser.parse_args(argv)
    run_server(args.server)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())