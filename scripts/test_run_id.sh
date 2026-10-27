#!/usr/bin/env bash
set -Eeuo pipefail
unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
source scripts/observability.sh
first="$(otel_log INFO 'Inicio' backup started)"
second="$(otel_log INFO 'Conclusao' backup success)"
[[ "$first" == *"\"run_id\":\"${OTEL_RUN_ID}\""* ]]
[[ "$second" == *"\"run_id\":\"${OTEL_RUN_ID}\""* ]]
printf 'Identificador preservado entre eventos do backup.\n'
