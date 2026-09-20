#!/usr/bin/env bash

set -Eeuo pipefail

readonly R2_PREFIX="postgresql/"
readonly OPERATION="backup-restore"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability.sh
source "${script_directory}/observability.sh"
otel_init "restore"

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
  otel_log ERROR "Restauracao interrompida por erro inesperado" "$OPERATION" error >&2
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

backup_reference="${1:-}"
[[ -n "$backup_reference" ]] || fail "uso: $0 <postgresql/arquivo.dump|s3://bucket/postgresql/arquivo.dump>"

require_command aws
require_command pg_restore
require_command mktemp

require_variable R2_ENDPOINT
require_variable R2_BUCKET_NAME
require_variable RESTORE_PG_HOST
require_variable RESTORE_PG_PORT
require_variable RESTORE_PG_DATABASE
require_variable RESTORE_PG_USER
require_variable RESTORE_PG_PASSWORD
require_variable CONFIRM_RESTORE_DATABASE

[[ "$CONFIRM_RESTORE_DATABASE" == "$RESTORE_PG_DATABASE" ]] || {
  fail "CONFIRM_RESTORE_DATABASE deve ser identico a RESTORE_PG_DATABASE"
}

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export PGPASSWORD="$RESTORE_PG_PASSWORD"
export PGSSLMODE=require

require_variable AWS_ACCESS_KEY_ID
require_variable AWS_SECRET_ACCESS_KEY

if [[ "$backup_reference" == s3://* ]]; then
  expected_base="s3://${R2_BUCKET_NAME}/"
  [[ "$backup_reference" == "${expected_base}${R2_PREFIX}"* ]] || {
    fail "o backup deve estar no bucket configurado e sob o prefixo ${R2_PREFIX}"
  }
  object_key="${backup_reference#${expected_base}}"
else
  object_key="$backup_reference"
fi

[[ "$object_key" == "${R2_PREFIX}"* ]] || fail "a chave deve permanecer no prefixo ${R2_PREFIX}"
[[ "$object_key" == *.dump ]] || fail "o objeto selecionado deve possuir extensao .dump"

temporary_directory="$(mktemp -d)"
local_backup="${temporary_directory}/backup.dump"

cleanup() {
  rm -f -- "$local_backup"
  rmdir -- "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT

log "Baixando $(basename "$object_key") do Cloudflare R2"
aws s3 cp \
  "s3://${R2_BUCKET_NAME}/${object_key}" \
  "$local_backup" \
  --endpoint-url "$R2_ENDPOINT" \
  --only-show-errors

[[ -f "$local_backup" ]] || fail "o download nao criou o arquivo local"
[[ -s "$local_backup" ]] || fail "o arquivo baixado esta vazio"

log "Validando o formato custom do PostgreSQL"
pg_restore --list "$local_backup" >/dev/null

log "Iniciando restauracao manual no banco confirmado: ${RESTORE_PG_DATABASE}"
pg_restore \
  --host="$RESTORE_PG_HOST" \
  --port="$RESTORE_PG_PORT" \
  --username="$RESTORE_PG_USER" \
  --dbname="$RESTORE_PG_DATABASE" \
  --no-password \
  --no-owner \
  --no-privileges \
  --single-transaction \
  --exit-on-error \
  "$local_backup"

otel_log INFO "Restauracao concluida sem erros" "$OPERATION" success
