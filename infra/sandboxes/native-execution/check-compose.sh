#!/usr/bin/env bash
# Resolve the real Compose merge without credentials, containers or image builds.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
check() {
  docker compose --env-file /dev/null "$@" \
    -f infra/compose/docker-compose.execution.yml \
    config --no-interpolate --format json |
    python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
computer = services["computer"]
environment = services["supervisor"]["environment"]
if isinstance(environment, list):
    environment = dict(value.split("=", 1) for value in environment if "=" in value)
assert "build" not in computer, "Prepared computers must not rebuild the base image"
assert computer["pull_policy"] == "never", "Pull the pinned image before deployment"
assert computer["image"] == environment["RAKAZO_COMPUTER_IMAGE"], "Computer images must match"
assert computer["command"] == ["true"], "The image helper must remain a one-shot service"
'
}
check -f infra/compose/docker-compose.yml
check -f infra/compose/docker-compose.images.yml
check -f infra/compose/docker-compose.prod.yml -f infra/compose/docker-compose.prod.docker.yml
echo 'Prepared computer composition passed for all Docker stacks.'
