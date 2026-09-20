#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temporary_directory="$(mktemp -d)"

cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

fail() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local content="$1"
  local expected="$2"
  local description="$3"
  [[ "$content" == *"$expected"* ]] || fail "$description"
}

unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
unset GITHUB_ACTIONS

# shellcheck source=scripts/observability.sh
source "${script_directory}/observability.sh"
otel_init test-worker
console_output="$(otel_log INFO 'Log local sem credenciais' test-local success)"
assert_contains "$console_output" '"service.name":"postgresql-backup"' 'service.name ausente no console'
assert_contains "$console_output" '"level":"INFO"' 'nivel ausente no console'
assert_contains "$console_output" '"message":"Log local sem credenciais"' 'mensagem ausente no console'

mkdir -p "${temporary_directory}/bin"
cat >"${temporary_directory}/bin/python" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$OTEL_TEST_CAPTURE_ARGUMENTS"
printf '%s\n' "$OTEL_EXPORTER_OTLP_ENDPOINT" >"$OTEL_TEST_CAPTURE_ENDPOINT"
MOCK_PYTHON
chmod +x "${temporary_directory}/bin/python"

export OTEL_PYTHON_BIN="${temporary_directory}/bin/python"
export OTEL_TEST_CAPTURE_ARGUMENTS="${temporary_directory}/captured-arguments"
export OTEL_TEST_CAPTURE_ENDPOINT="${temporary_directory}/captured-endpoint"
export OTEL_EXPORTER_OTLP_ENDPOINT='https://otlp.example.test/otlp'
export OTEL_EXPORTER_OTLP_HEADERS='Authorization=Basic%20TEST_ONLY'

otel_log ERROR 'Falha controlada' test-export error >/dev/null

arguments_content="$(<"$OTEL_TEST_CAPTURE_ARGUMENTS")"
endpoint_content="$(<"$OTEL_TEST_CAPTURE_ENDPOINT")"
assert_contains "$arguments_content" 'otel_export.py' 'exportador OpenTelemetry nao foi chamado'
assert_contains "$arguments_content" 'ERROR' 'nivel nao foi encaminhado ao exportador'
assert_contains "$arguments_content" 'Falha controlada' 'mensagem nao foi encaminhada ao exportador'
assert_contains "$arguments_content" 'test-worker' 'worker nao foi encaminhado ao exportador'
assert_contains "$endpoint_content" 'https://otlp.example.test/otlp' 'endpoint OTLP nao chegou ao exportador'

if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
  PYTHONPYCACHEPREFIX="$temporary_directory/pycache" \
    python3 -m py_compile "${script_directory}/otel_export.py"
fi

printf 'Testes de observabilidade concluidos com sucesso.\n'
