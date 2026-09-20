#!/usr/bin/env bash

set -Eeuo pipefail

readonly R2_PREFIX="postgresql"
readonly OPERATION="backup-upload"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability.sh
source "${script_directory}/observability.sh"
otel_init "r2-upload"

log() {
  otel_log INFO "$*" "$OPERATION"
}

fail() {
  otel_log ERROR "$*" "$OPERATION" error >&2
  exit 1
}

unexpected_error() {
  local exit_code=$?
  trap - ERR
  otel_log ERROR "Upload interrompido por erro inesperado" "$OPERATION" error >&2
  exit "$exit_code"
}
trap unexpected_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "comando obrigatorio nao encontrado: $1"
}

require_variable() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || fail "variavel obrigatoria ausente: ${variable_name}"
}

backup_file="${1:-}"
object_key="${2:-}"

[[ -n "$backup_file" ]] || fail "uso: $0 <arquivo.dump> [chave-do-objeto]"
[[ -f "$backup_file" ]] || fail "arquivo de backup nao encontrado"
[[ -s "$backup_file" ]] || fail "arquivo de backup vazio"

require_command aws
require_variable R2_ENDPOINT
require_variable R2_BUCKET_NAME

# Aceita as variaveis do projeto e as converte para o padrao do AWS CLI.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

require_variable AWS_ACCESS_KEY_ID
require_variable AWS_SECRET_ACCESS_KEY

if [[ -z "$object_key" ]]; then
  object_key="${R2_PREFIX}/$(basename "$backup_file")"
fi

[[ "$object_key" == "${R2_PREFIX}/"* ]] || fail "a chave deve permanecer no prefixo ${R2_PREFIX}/"

log "Enviando $(basename "$backup_file") para ${object_key}"
aws s3 cp \
  "$backup_file" \
  "s3://${R2_BUCKET_NAME}/${object_key}" \
  --endpoint-url "$R2_ENDPOINT" \
  --only-show-errors

# head-object falha se o objeto nao estiver disponivel apos o upload.
aws s3api head-object \
  --bucket "$R2_BUCKET_NAME" \
  --key "$object_key" \
  --endpoint-url "$R2_ENDPOINT" \
  --output json >/dev/null

otel_log INFO "Upload confirmado no Cloudflare R2" "$OPERATION" success
aws s3 ls \
  "s3://${R2_BUCKET_NAME}/${object_key}" \
  --endpoint-url "$R2_ENDPOINT"
