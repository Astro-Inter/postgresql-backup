#!/usr/bin/env bash

set -Eeuo pipefail

readonly OPERATION="recovery-test"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability.sh
source "${script_directory}/observability.sh"
otel_init "recovery-test"

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
  otel_log ERROR "Teste de recuperacao interrompido por erro inesperado" "$OPERATION" error >&2
  exit "$exit_code"
}
trap unexpected_error ERR

require_variable() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || fail "variavel obrigatoria ausente: ${variable_name}"
}

backup_reference="${1:-}"
[[ -n "$backup_reference" ]] || fail "uso: $0 <postgresql/arquivo.dump|s3://bucket/postgresql/arquivo.dump>"

command -v psql >/dev/null 2>&1 || fail "comando obrigatorio nao encontrado: psql"

require_variable RESTORE_PG_HOST
require_variable RESTORE_PG_PORT
require_variable RESTORE_PG_DATABASE
require_variable RESTORE_PG_USER
require_variable RESTORE_PG_PASSWORD
require_variable CONFIRM_RESTORE_DATABASE
require_variable RECOVERY_CHECK_SQL
require_variable RECOVERY_EXPECTED_RESULT

[[ "$CONFIRM_RESTORE_DATABASE" == "$RESTORE_PG_DATABASE" ]] || {
  fail "CONFIRM_RESTORE_DATABASE deve ser identico a RESTORE_PG_DATABASE"
}

check_sql="${RECOVERY_CHECK_SQL%;}"
[[ "$check_sql" =~ ^[[:space:]]*SELECT[[:space:]] ]] || {
  fail "RECOVERY_CHECK_SQL deve conter uma unica consulta SELECT"
}
[[ "$check_sql" != *';'* ]] || fail "RECOVERY_CHECK_SQL nao pode conter multiplas instrucoes"

export PGPASSWORD="$RESTORE_PG_PASSWORD"
export PGSSLMODE=require

psql_base=(
  psql
  --host="$RESTORE_PG_HOST"
  --port="$RESTORE_PG_PORT"
  --username="$RESTORE_PG_USER"
  --dbname="$RESTORE_PG_DATABASE"
  --no-password
  --set=ON_ERROR_STOP=1
  --tuples-only
  --no-align
)

log "Confirmando que o banco de teste esta vazio"
existing_tables="$("${psql_base[@]}" --command="
  SELECT count(*)
  FROM pg_catalog.pg_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
")"
existing_tables="${existing_tables//$'\r'/}"
[[ "$existing_tables" =~ ^[0-9]+$ ]] || fail "nao foi possivel validar o estado inicial do banco"
(( existing_tables == 0 )) || fail "o banco de teste deve estar vazio antes da restauracao"

bash "${script_directory}/restore_backup.sh" "$backup_reference"

log "Verificando objetos restaurados"
object_counts="$("${psql_base[@]}" --field-separator=' ' --command="
    SELECT
      (SELECT count(*) FROM pg_catalog.pg_tables
       WHERE schemaname NOT IN ('pg_catalog', 'information_schema')),
      (SELECT count(*) FROM pg_catalog.pg_views
       WHERE schemaname NOT IN ('pg_catalog', 'information_schema')),
      (SELECT count(*) FROM pg_catalog.pg_sequences
       WHERE schemaname NOT IN ('pg_catalog', 'information_schema'));
  ")"
object_counts="${object_counts//$'\r'/}"
read -r table_count view_count sequence_count <<< "$object_counts"

[[ "$table_count" =~ ^[0-9]+$ ]] || fail "contagem de tabelas invalida"
(( table_count > 0 )) || fail "nenhuma tabela de aplicacao foi encontrada apos a restauracao"

log "Objetos encontrados: ${table_count} tabela(s), ${view_count} view(s), ${sequence_count} sequencia(s)"

log "Executando verificacao de dados definida pela equipe"
actual_result="$("${psql_base[@]}" --command="$check_sql")"
actual_result="${actual_result//$'\r'/}"

[[ "$actual_result" == "$RECOVERY_EXPECTED_RESULT" ]] || {
  fail "a verificacao de dados nao retornou o resultado esperado"
}

otel_log INFO "Teste de recuperacao concluido com estrutura e dados validados" "$OPERATION" success
