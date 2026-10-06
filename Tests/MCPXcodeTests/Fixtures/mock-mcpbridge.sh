#!/bin/sh
set -eu

mode="${MOCK_XCODE_MODE:-normal}"
revision="${MOCK_XCODE_REVISION:-2025-06-18}"
log_file="${MOCK_XCODE_LOG_FILE:-}"
instance=1
list_count=0
initialize_id=""

if [ -n "$log_file" ]; then
  launch_count=0
  if [ -f "$log_file" ]; then
    launch_count="$(/usr/bin/grep -c '^__launch__$' "$log_file" || true)"
  fi
  instance=$((launch_count + 1))
  printf '%s\n' '__launch__' >> "$log_file"
fi

log_line() {
  if [ -n "$log_file" ]; then
    printf '%s\n' "$1" >> "$log_file"
  fi
}

request_id() {
  printf '%s' "$1" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/'
}

while IFS= read -r line; do
  log_line "$line"

  case "$line" in
    *'"id":"'*)
      printf '%s\n' 'mock bridge rejects string request ids' >&2
      exit 71
      ;;
  esac

  case "$line" in
    *'"method":"initialize"'*)
      id="$(request_id "$line")"
      initialize_id="$id"
      if [ "$mode" = "ignore-initialize" ]; then
        continue
      fi
      if [ "$mode" = "cancel-cleanup-reconnect" ] && [ "$instance" -eq 1 ]; then
        continue
      fi
      if [ "$mode" = "delay-initialize" ]; then
        /bin/sleep 0.15
      fi
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"$revision\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"mock-xcode\",\"version\":\"1.0.0\"}}}"
      ;;

    *'"method":"notifications/initialized"'*)
      ;;

    *'"method":"tools/list"'*)
      id="$(request_id "$line")"
      list_count=$((list_count + 1))
      if [ "$mode" = "exit-after-notification" ]; then
        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
      fi
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"XcodeListWindows\",\"description\":\"Mock Xcode tool\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}"
      if [ "$mode" = "duplicate-list-response" ]; then
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"XcodeListWindows\",\"description\":\"Mock Xcode tool\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}"
      fi
      if [ "$mode" = "late-response-after-retirement-window" ] && [ "$list_count" -eq 256 ]; then
        # The initialize response is older than the retired-ID ledger window in the old client.
        # A correct monotonic-ID implementation ignores this duplicate indefinitely.
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$initialize_id,\"result\":{\"protocolVersion\":\"$revision\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"mock-xcode\",\"version\":\"1.0.0\"}}}"
      fi
      if [ "$mode" = "exit-after-list" ] || [ "$mode" = "exit-after-notification" ]; then
        exit 0
      fi
      if [ "$mode" = "close-stdout-after-list" ]; then
        log_line '__stdout_closed__'
        exec 1>&-
        /bin/sleep 0.30
        exit 0
      fi
      ;;

    *'"method":"tools/call"'*)
      id="$(request_id "$line")"
      if [ "$mode" = "ignore-tool-call" ]; then
        continue
      fi
      if [ "$mode" = "delay-tool-call" ]; then
        /bin/sleep 0.15
      fi
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"isError\":false}}"
      ;;

    *'"method":"notifications/cancelled"'*)
      ;;
  esac
done

if [ "$mode" = "cancel-cleanup-reconnect" ] && [ "$instance" -eq 1 ]; then
  # Keep the retired process alive briefly after stdin closes so the client has a deterministic
  # stopping window in which a new connect must queue rather than share the cancelled attempt.
  /bin/sleep 0.20
fi
