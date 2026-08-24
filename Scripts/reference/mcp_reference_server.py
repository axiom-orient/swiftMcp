"""Stateless streamable-HTTP reference server built on the official Python SDK.

This fixture exists only for external conformance verification. It exposes the same
strict surface the repository's own conformance fixtures do — discovery plus an echo
tool — so `mcp-conformance-client` can run its sequence unchanged against an ecosystem
reference implementation. It is not a sample app and is not part of any shipped product.
"""

import os

import uvicorn
from mcp.server.mcpserver import MCPServer


def build_server() -> MCPServer:
    server = MCPServer(
        name="swiftmcp-reference",
        version="1.0.0",
        instructions="External conformance reference server.",
    )

    @server.tool(name="echo", description="Returns the supplied text.")
    def echo(text: str) -> str:
        """Returns the supplied text."""
        return text

    return server


def main() -> None:
    port = int(os.environ.get("MCP_REFERENCE_PORT", "8000"))
    server = build_server()
    # json_response=True keeps every answer a single JSON body; stateless_http=True is the
    # 2026-07-28 mode: no protocol-level sessions and no initialize handshake requirement.
    app = server.streamable_http_app(
        json_response=True,
        stateless_http=True,
        host="127.0.0.1",
    )
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
