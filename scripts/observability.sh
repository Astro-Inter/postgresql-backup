#!/usr/bin/env bash

# Logging estruturado para console com exportacao OTLP/HTTP opcional.
# Este arquivo deve ser carregado com: source scripts/observability.sh

readonly SERVICE_NAME="postgresql-backup"
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  readonly DEPLOYMENT_ENVIRONMENT="production"
else
  readonly DEPLOYMENT_ENVIRONMENT="local"
fi
OTEL_SERVICE_VERSION="${OTEL_SERVICE_VERSION:-${GITHUB_SHA:-}}"
OTEL_JOB_NAME="${OTEL_JOB_NAME:-postgresql-backup}"
OTEL_CURRENT_WORKER="${OTEL_WORKER_NAME:-shell}"
OTEL_EXPORT_WARNING_REPORTED=0
OTEL_OBSERVABILITY_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

otel_init() {
  OTEL_CURRENT_WORKER="${1:-${OTEL_WORKER_NAME:-shell}}"
}

otel_json_escape() {
  local input="${1-}"
  local output=""
  local character code index
  local LC_ALL=C

  for ((index = 0; index < ${#input}; index += 1)); do
    character="${input:index:1}"
    case "$character" in
      '"') output+='\"' ;;
      '\') output+='\\' ;;
      $'\b') output+='\b' ;;
      $'\f') output+='\f' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        printf -v code '%d' "'$character"
        if ((code < 32)); then
          printf -v character '\\u%04x' "$code"
        fi
        output+="$character"
        ;;
    esac
  done

  REPLY="$output"
}

otel_report_export_warning() {
  ((OTEL_EXPORT_WARNING_REPORTED == 0)) || return 0
  OTEL_EXPORT_WARNING_REPORTED=1

  local timestamp
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  otel_json_escape "$timestamp"
  local escaped_timestamp="$REPLY"
  otel_json_escape "$SERVICE_NAME"
  local escaped_service="$REPLY"

  printf '{"timestamp":"%s","level":"WARN","service.name":"%s","message":"Falha ao exportar log via OTLP; a execucao principal continua"}\n' \
    "$escaped_timestamp" "$escaped_service" >&2
}

otel_find_python() {
  if [[ -n "${OTEL_PYTHON_BIN:-}" && -x "${OTEL_PYTHON_BIN}" ]]; then
    REPLY="$OTEL_PYTHON_BIN"
  elif command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
    REPLY="$(command -v python3)"
  elif command -v python >/dev/null 2>&1 && python -c '' >/dev/null 2>&1; then
    REPLY="$(command -v python)"
  else
    REPLY=""
  fi
}

otel_export() {
  local level="$1"
  local message="$2"
  local operation="$3"
  local status="$4"
  local duration_ms="$5"

  # A observabilidade e opcional: sem as duas variaveis, fica somente no console.
  [[ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" && -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]] || return 0

  otel_find_python
  local python_bin="$REPLY"
  if [[ -z "$python_bin" ]]; then
    otel_report_export_warning
    return 0
  fi

  if ! "$python_bin" "${OTEL_OBSERVABILITY_DIRECTORY}/otel_export.py" \
      --level "$level" \
      --message "$message" \
      --worker "$OTEL_CURRENT_WORKER" \
      --operation "$operation" \
      --status "$status" \
      --duration-ms "$duration_ms" >/dev/null 2>&1; then
    otel_report_export_warning
  fi

  return 0
}

otel_log() {
  local level="${1:-INFO}"
  local message="${2:-}"
  local operation="${3:-}"
  local status="${4:-}"
  local duration_ms="${5:-}"
  local timestamp

  level="${level^^}"
  case "$level" in
    TRACE|DEBUG|INFO|WARN|ERROR|FATAL) ;;
    *) level=INFO ;;
  esac

  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  otel_json_escape "$timestamp"
  local escaped_timestamp="$REPLY"
  otel_json_escape "$SERVICE_NAME"
  local escaped_service="$REPLY"
  otel_json_escape "$message"
  local escaped_message="$REPLY"
  otel_json_escape "$OTEL_CURRENT_WORKER"
  local escaped_worker="$REPLY"
  otel_json_escape "$DEPLOYMENT_ENVIRONMENT"
  local escaped_environment="$REPLY"

  printf '{"timestamp":"%s","level":"%s","service.name":"%s","environment":"%s","worker":"%s","message":"%s"' \
    "$escaped_timestamp" "$level" "$escaped_service" "$escaped_environment" "$escaped_worker" "$escaped_message"
  if [[ -n "$operation" ]]; then
    otel_json_escape "$operation"
    printf ',"operation":"%s"' "$REPLY"
  fi
  if [[ -n "$duration_ms" && "$duration_ms" =~ ^[0-9]+$ ]]; then
    printf ',"duration_ms":%s' "$duration_ms"
  fi
  if [[ -n "$status" ]]; then
    otel_json_escape "$status"
    printf ',"status":"%s"' "$REPLY"
  fi
  printf '}\n'

  otel_export "$level" "$message" "$operation" "$status" "$duration_ms"
  return 0
}
