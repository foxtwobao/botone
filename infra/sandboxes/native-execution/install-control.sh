#!/usr/bin/env bash
# Install an immutable, rollbackable host release. No credentials are printed.
set -euo pipefail
[[ "$EUID" == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
image="${1:?Usage: install-control.sh IMAGE PRIVATE_CONFIG COMPUTER_HOMES}"
configuration="$(realpath "${2:?Missing private configuration}")"
homes="$(realpath "${3:?Missing computer homes directory}")"
for command in docker nsenter unshare mount setpriv systemctl; do command -v "$command" >/dev/null; done
[[ "$(stat -fc %T /sys/fs/cgroup)" == cgroup2fs ]]
for target in "$configuration" "$homes"; do
  [[ "$target" =~ ^/[a-zA-Z0-9/_.-]+$ ]] || { echo 'Unsupported installation path.' >&2; exit 1; }
done
[[ "$(stat -c %u "$configuration")" == 0 && "$(stat -c %a "$configuration")" == 600 ]]
[[ -d "$homes" && "$homes" != / ]]
container="$(docker create "$image")"
temporary="$(mktemp -d /opt/execution-release.XXXXXX)"
trap 'docker rm -f "$container" >/dev/null; rm -rf "$temporary"' EXIT
docker cp "$container:/app" "$temporary/app"
install -d "$temporary/bin"
docker cp "$container:/usr/local/bin/node" "$temporary/bin/node"
chmod 755 "$temporary/bin/node"
revision="$(cat "$temporary/app/.execution-revision")"
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
control_root="$("$temporary/bin/node" --input-type=module - "$configuration" "$revision" <<'JS'
import fs from 'node:fs';
const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!config.managed || config.managed.runtimeRevision!==process.argv[3] ||
  typeof config.root!=='string' || !/^\/(var\/lib|srv)\/[a-zA-Z0-9/_.-]+$/.test(config.root) ||
  config.root.split('/').includes('..')) process.exit(1);
console.log(config.root);
JS
)"
[[ "$control_root" != "$homes" && "$control_root" != "$homes/"* && "$homes" != "$control_root/"* ]]
install -d -m 700 "$control_root"
release="/opt/execution-releases/$revision"
install -d -m 755 /opt/execution-releases
[[ ! -e "$release" ]] || { echo 'Release already installed; use the existing release.' >&2; exit 1; }
mv "$temporary" "$release"
if [[ -f /etc/systemd/system/rakazo-execution.service ]]; then
  cp /etc/systemd/system/rakazo-execution.service "$release/previous.service"
fi
cat > "$release/execution.service" <<UNIT
[Unit]
Description=Optional computer execution service
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=$release/bin/node $release/app/packages/adapters/dist/native-harness/daemon.js $configuration
Restart=on-failure
RestartSec=5
UMask=0077
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$control_root $homes /sys/fs/cgroup

[Install]
WantedBy=multi-user.target
UNIT
install -m 644 "$release/execution.service" /etc/systemd/system/rakazo-execution.service
systemctl daemon-reload
if systemctl is-active --quiet rakazo-execution; then
  echo 'Release installed. The current service is unchanged; restart after its tasks finish.'
else
  systemctl enable --now rakazo-execution
fi
echo 'Keep the previous release and configuration for rollback.'
