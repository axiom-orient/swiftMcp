"""Official-SDK reference client driven against this repository's HTTP conformance server.

This fixture completes the reverse direction of external verification: the pinned Python
SDK acts as the client while the Swift implementation serves. It runs the same assertion
sequence as `mcp-conformance-client` and prints one PASS line on success. It is a
verification fixture, not a sample app.
"""

import asyncio
import sys

from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.exceptions import MCPError

STRICT_PROTOCOL_VERSION = "2026-07-28"


async def run(endpoint: str) -> None:
    async with streamable_http_client(endpoint) as streams:
        read_stream = getattr(streams, "read_stream", None)
        write_stream = getattr(streams, "write_stream", None)
        if read_stream is None:
            read_stream, write_stream = streams[0], streams[1]
        async with ClientSession(read_stream, write_stream) as session:
            discovery = await session.discover()
            assert discovery.supported_versions == [STRICT_PROTOCOL_VERSION], (
                discovery.supported_versions
            )

            listing = await session.list_tools()
            assert any(tool.name == "echo" for tool in listing.tools), (
                [tool.name for tool in listing.tools]
            )

            result = await session.call_tool("echo", {"text": "conformance"})
            assert result.result_type == "complete", result.result_type
            assert not result.is_error
            texts = [
                block.text for block in result.content if getattr(block, "text", None)
            ]
            assert "conformance" in texts, texts

            # Peers legitimately report an unknown tool as an RPC error or as an
            # isError result; conformance only requires one of them.
            try:
                unknown = await session.call_tool("definitely-not-registered", {})
                assert unknown.is_error or unknown.result_type != "complete", (
                    "unknown tool unexpectedly succeeded"
                )
            except MCPError:
                pass


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: mcp_reference_client.py <endpoint-url>", file=sys.stderr)
        raise SystemExit(2)
    asyncio.run(run(sys.argv[1]))
    print("PASS strict discovery/list/call/unknown-tool")


if __name__ == "__main__":
    main()
