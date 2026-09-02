#!/usr/bin/env python3
"""Transparent stdio proxy for explicit live Xcode qualification.

This is test-only evidence tooling. It launches `/usr/bin/xcrun mcpbridge`, forwards stdin/stdout
byte-for-byte by line, mirrors stderr, and records an ordered JSONL transcript without changing the
production MCPXcode surface.
"""

import json
import os
import subprocess
import sys
import threading
import signal

transcript_path = os.environ.get("MCP_XCODE_TRANSCRIPT_PATH")
if not transcript_path:
    print("MCP_XCODE_TRANSCRIPT_PATH is required", file=sys.stderr)
    sys.exit(64)

lock = threading.Lock()
transcript = open(transcript_path, "w", encoding="utf-8", buffering=1)


def command_output(argv):
    try:
        result = subprocess.run(argv, check=False, capture_output=True, text=True)
        text = (result.stdout + result.stderr).strip()
        return {"command": argv, "status": result.returncode, "output": text}
    except Exception as error:  # evidence collection must not hide launch failures
        return {"command": argv, "error": repr(error)}


def record(direction, raw):
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    raw = raw.rstrip("\n")
    entry = {"direction": direction, "raw": raw}
    try:
        entry["message"] = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        pass
    with lock:
        transcript.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")


with lock:
    transcript.write(
        json.dumps(
            {
                "meta": {
                    "xcodebuild": command_output(["/usr/bin/xcodebuild", "-version"]),
                    "sw_vers": command_output(["/usr/bin/sw_vers"]),
                    "requestedRevision": os.environ.get("MCP_XCODE_PROTOCOL_REVISION", "2025-06-18"),
                }
            },
            ensure_ascii=False,
        )
        + "\n"
    )

child = subprocess.Popen(
    ["/usr/bin/xcrun", "mcpbridge"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=os.environ.copy(),
    bufsize=0,
)


def forward_signal(signum, _frame):
    if child.poll() is None:
        try:
            child.send_signal(signum)
        except ProcessLookupError:
            pass


signal.signal(signal.SIGTERM, forward_signal)
signal.signal(signal.SIGINT, forward_signal)


def pump_stdout():
    assert child.stdout is not None
    for line in iter(child.stdout.readline, b""):
        record("xcode->client", line)
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()


def pump_stderr():
    assert child.stderr is not None
    for line in iter(child.stderr.readline, b""):
        record("xcode-stderr", line)
        sys.stderr.buffer.write(line)
        sys.stderr.buffer.flush()


stdout_thread = threading.Thread(target=pump_stdout, daemon=True)
stderr_thread = threading.Thread(target=pump_stderr, daemon=True)
stdout_thread.start()
stderr_thread.start()

try:
    assert child.stdin is not None
    for line in iter(sys.stdin.buffer.readline, b""):
        record("client->xcode", line)
        child.stdin.write(line)
        child.stdin.flush()
finally:
    try:
        if child.stdin is not None:
            child.stdin.close()
    except BrokenPipeError:
        pass

status = child.wait()
stdout_thread.join(timeout=1)
stderr_thread.join(timeout=1)
record("proxy", f"mcpbridge-exit={status}")
transcript.close()
sys.exit(status)
