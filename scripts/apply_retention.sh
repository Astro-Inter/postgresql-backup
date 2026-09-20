#!/usr/bin/env bash

set -Eeuo pipefail

readonly R2_PREFIX="postgresql/"
readonly OPERATION="backup-retention"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability.sh
source "${script_directory}/observability.sh"
otel_init "retention"

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
  otel_log ERROR "Retencao interrompida por erro inesperado" "$OPERATION" error >&2
  exit "$exit_code"
}
trap unexpected_error ERR

require_variable() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || fail "variavel obrigatoria ausente: ${variable_name}"
}

command -v aws >/dev/null 2>&1 || fail "comando obrigatorio nao encontrado: aws"
command -v date >/dev/null 2>&1 || fail "comando obrigatorio nao encontrado: date"

require_variable R2_ENDPOINT
require_variable R2_BUCKET_NAME

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

require_variable AWS_ACCESS_KEY_ID
require_variable AWS_SECRET_ACCESS_KEY

retention_days="${BACKUP_RETENTION_DAYS:-7}"
protected_object_key="${1:-${BACKUP_OBJECT_KEY:-}}"

[[ "$retention_days" =~ ^[0-9]+$ ]] || fail "BACKUP_RETENTION_DAYS deve ser um numero inteiro"
(( retention_days >= 1 )) || fail "BACKUP_RETENTION_DAYS deve ser maior ou igual a 1"

if [[ -n "$protected_object_key" && "$protected_object_key" != "${R2_PREFIX}"* ]]; then
  fail "o objeto protegido deve permanecer no prefixo ${R2_PREFIX}"
fi

cutoff_epoch="$(date -u -d "${retention_days} days ago" +%s)"

log "Listando objetos sob o prefixo ${R2_PREFIX}"
objects="$({
  aws s3api list-objects-v2 \
    --bucket "$R2_BUCKET_NAME" \
    --prefix "$R2_PREFIX" \
    --endpoint-url "$R2_ENDPOINT" \
    --query 'Contents[].[Key,LastModified]' \
    --output text
})" || fail "nao foi possivel listar os backups"

removed_count=0

while IFS=$'\t' read -r object_key last_modified; do
  [[ -n "$object_key" && "$object_key" != "None" ]] || continue
  [[ "$object_key" == "${R2_PREFIX}"* ]] || fail "objeto fora do prefixo seguro retornado pela listagem"
  [[ "$object_key" != "$R2_PREFIX" ]] || continue

  if [[ -n "$protected_object_key" && "$object_key" == "$protected_object_key" ]]; then
    continue
  fi

  modified_epoch="$(date -u -d "$last_modified" +%s)" || fail "data invalida recebida para um objeto"

  if (( modified_epoch < cutoff_epoch )); then
    aws s3 rm \
      "s3://${R2_BUCKET_NAME}/${object_key}" \
      --endpoint-url "$R2_ENDPOINT" \
      --only-show-errors
    log "Backup removido por retencao: $(basename "$object_key")"
    ((removed_count += 1))
  fi
done <<< "$objects"

otel_log INFO "Retencao concluida: ${removed_count} backup(s) removido(s); janela de ${retention_days} dia(s)" "$OPERATION" success
