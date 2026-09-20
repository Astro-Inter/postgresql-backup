#!/usr/bin/env bash

set -uo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability.sh
source "${script_directory}/observability.sh"

level="${1:-INFO}"
message="${2:-}"
operation="${3:-}"
status="${4:-}"
duration_ms="${5:-}"

otel_init "${OTEL_WORKER_NAME:-github-actions}"
otel_log "$level" "$message" "$operation" "$status" "$duration_ms"
