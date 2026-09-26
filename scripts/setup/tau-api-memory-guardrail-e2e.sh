#!/usr/bin/env bash
# Opt-in, disposable-host proof that systemd restarts tau-api after cgroup OOM.
set -euo pipefail

[[ ${FICUS_API_MEMORY_E2E:-0} == 1 ]] || { echo 'Refusing: set FICUS_API_MEMORY_E2E=1 on a disposable host' >&2; exit 2; }
[[ ${EUID} -eq 0 ]] || { echo 'Refusing: must run as root' >&2; exit 2; }
[[ $(ps -p 1 -o comm=) == systemd ]] || { echo 'Refusing: PID 1 is not systemd' >&2; exit 2; }
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || { echo 'Refusing: cgroup v2 is required' >&2; exit 2; }
grep -qw memory /sys/fs/cgroup/cgroup.controllers || { echo 'Refusing: memory controller unavailable' >&2; exit 2; }
command -v python3 >/dev/null
command -v curl >/dev/null

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
suffix="${$}-$(date +%s)"
unit="tau-api-memory-e2e-${suffix}"
runtime_dir="/run/${unit}"
unit_file="/run/systemd/system/${unit}.service"
dropin_dir="/run/systemd/system/${unit}.service.d"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

cleanup() {
  systemctl stop "${unit}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${unit}.service" >/dev/null 2>&1 || true
  rm -rf -- "${unit_file}" "${dropin_dir}" "${runtime_dir}"
  systemctl daemon-reload >/dev/null 2>&1 || true
}
diagnostics() {
  systemctl show "${unit}.service" -p Result -p NRestarts -p MemoryCurrent -p MemoryPeak -p MemoryHigh -p MemoryMax >&2 || true
  journalctl -u "${unit}.service" -b --no-pager >&2 || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then diagnostics; fi; cleanup; exit $rc' EXIT

mkdir -p "${runtime_dir}" "${dropin_dir}"
sed -e 's|@DB_AFTER@||g' -e 's|@RUN_USER@|root|g' \
  -e "s|@DEST@|${runtime_dir}|g" -e "s|@RUN_ROOT@|${runtime_dir}|g" -e 's|@BUN_DIR@|/usr/bin|g' \
  -e 's|@BUN_BIN@|/usr/bin/false|g' \
  "${SCRIPT_DIR}/systemd/tau-api.service.tmpl" >"${unit_file}"
cat >"${runtime_dir}/runner.py" <<'PY'
import http.server, os
state, port = os.environ['STATE_FILE'], int(os.environ['TEST_PORT'])
if not os.path.exists(state):
    open(state, 'w').close()
    # Parallel children create irreclaimable anonymous pressure. A single
    # allocator can remain reclaim-throttled just below memory.max on some
    # kernels; competing allocations force the cgroup OOM path decisively.
    for _ in range(8):
        if os.fork() == 0:
            block=bytearray(128*1024*1024)
            for offset in range(0, len(block), 4096): block[offset]=1
            while True: pass
    while True: os.wait()
else:
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.end_headers(); self.wfile.write(b'tau-api-memory-e2e-ok')
        def log_message(self, *_): pass
    http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
PY
cat >"${dropin_dir}/test.conf" <<EOF_DROPIN
[Service]
ExecStart=
ExecStart=/usr/bin/python3 ${runtime_dir}/runner.py
EnvironmentFile=
Environment=STATE_FILE=${runtime_dir}/generation
Environment=TEST_PORT=${port}
WorkingDirectory=${runtime_dir}
User=root
MemoryHigh=48M
MemoryMax=64M
MemorySwapMax=0
EOF_DROPIN

systemd-analyze verify "${unit_file}"
systemctl daemon-reload
systemctl start "${unit}.service"

for _ in $(seq 1 90); do
  if curl --fail --silent --max-time 1 "http://127.0.0.1:${port}/" | grep -qx 'tau-api-memory-e2e-ok'; then break; fi
  sleep 1
done
curl --fail --silent --max-time 2 "http://127.0.0.1:${port}/" | grep -qx 'tau-api-memory-e2e-ok'
[[ $(systemctl show "${unit}.service" -p MemoryHigh --value) == 50331648 ]]
[[ $(systemctl show "${unit}.service" -p MemoryMax --value) == 67108864 ]]
(( $(systemctl show "${unit}.service" -p NRestarts --value) >= 1 ))
journal=$(journalctl -u "${unit}.service" -b --no-pager)
grep -qiE "oom-kill|out of memory|OOM killer" <<<"${journal}"
grep -qiE "Scheduled restart job|automatic restart" <<<"${journal}"
echo 'PASS: cgroup OOM was journaled; systemd restarted the unit; replacement served HTTP 200'
