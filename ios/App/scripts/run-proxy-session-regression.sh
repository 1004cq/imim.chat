#!/bin/bash
set -euo pipefail

proxy_script_dir="$(cd "$(dirname "$0")" && pwd)"
proxy_source="$proxy_script_dir/../App/ProxySession.swift"
proxy_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/imim-proxy-regression.XXXXXX")"
proxy_fixture_pid=""
cleanup_fixture() {
    if [[ -n "$proxy_fixture_pid" ]]; then
        kill -TERM "$proxy_fixture_pid" 2>/dev/null || true
        wait "$proxy_fixture_pid" 2>/dev/null || true
    fi
}
trap cleanup_fixture EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

node "$proxy_script_dir/proxy-session-fixture.mjs" > "$proxy_test_dir/fixture.log" 2>&1 &
proxy_fixture_pid=$!
for proxy_attempt in {1..100}; do
    if [[ -s "$proxy_test_dir/fixture.log" ]]; then break; fi
    kill -0 "$proxy_fixture_pid"
    sleep 0.1
done
proxy_ports="$(node -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8").split("\n")[0]);for(const k of ["httpPort","proxyPort","closedPort"])if(!Number.isInteger(d[k])||d[k]<1||d[k]>65535)process.exit(1);console.log([d.httpPort,d.proxyPort,d.closedPort].join(" "));' "$proxy_test_dir/fixture.log")"
read -r proxy_http_port proxy_socks_port proxy_closed_port <<< "$proxy_ports"

# Compile the real core together with the isolated fixture harness. No owner
# defaults, account, production token, proxy or normal Keychain service is used.
{ cat "$proxy_source" "$proxy_script_dir/ProxySessionRegression.swift"; } |
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc \
    -O -swift-version 6 -strict-concurrency=complete -D PROXY_REGRESSION_TESTS \
    -parse-as-library - -o "$proxy_test_dir/ProxySessionRegression"
"$proxy_test_dir/ProxySessionRegression" "$proxy_http_port" "$proxy_socks_port" "$proxy_closed_port"
printf 'Fixture stopped on exit. Regression artifacts retained: %s\n' "$proxy_test_dir"
