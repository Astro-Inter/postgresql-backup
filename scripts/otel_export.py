#!/usr/bin/env python3
"""Exporta um unico evento de log pelo OTLP/HTTP oficial do OpenTelemetry."""

from __future__ import annotations

import argparse
import os
import sys
import time


SERVICE_NAME = "postgresql-backup"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--level", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--operation", default="")
    parser.add_argument("--status", default="")
    parser.add_argument("--duration-ms", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()

    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT") or not os.environ.get(
        "OTEL_EXPORTER_OTLP_HEADERS"
    ):
        return 0

    try:
        from opentelemetry._logs.severity import SeverityNumber
        from opentelemetry.exporter.otlp.proto.http._log_exporter import (
            OTLPLogExporter,
        )
        from opentelemetry.sdk._logs import LoggerProvider
        from opentelemetry.sdk._logs.export import (
            LogRecordExportResult,
            LogRecordExporter,
            SimpleLogRecordProcessor,
        )
        from opentelemetry.sdk.resources import Resource
    except ImportError:
        return 2

    severity = {
        "TRACE": SeverityNumber.TRACE,
        "DEBUG": SeverityNumber.DEBUG,
        "INFO": SeverityNumber.INFO,
        "WARN": SeverityNumber.WARN,
        "ERROR": SeverityNumber.ERROR,
        "FATAL": SeverityNumber.FATAL,
    }.get(args.level.upper(), SeverityNumber.INFO)

    resource_attributes = {
        "service.name": SERVICE_NAME,
        "deployment.environment": (
            "production" if os.environ.get("GITHUB_ACTIONS") == "true" else "local"
        ),
    }
    service_version = os.environ.get("OTEL_SERVICE_VERSION")
    if service_version:
        resource_attributes["service.version"] = service_version

    log_attributes: dict[str, str | int] = {
        "job.name": os.environ.get("OTEL_JOB_NAME", "postgresql-backup"),
        "worker.name": args.worker,
    }
    if args.operation:
        log_attributes["operation"] = args.operation
    if args.status:
        log_attributes["status"] = args.status
    if args.duration_ms.isdigit():
        log_attributes["duration_ms"] = int(args.duration_ms)

    class TrackingExporter(LogRecordExporter):
        def __init__(self) -> None:
            self.delegate = OTLPLogExporter()
            self.last_result = None

        def export(self, batch):
            self.last_result = self.delegate.export(batch)
            return self.last_result

        def shutdown(self):
            return self.delegate.shutdown()

        def force_flush(self, timeout_millis: int = 10_000) -> bool:
            force_flush = getattr(self.delegate, "force_flush", None)
            return True if force_flush is None else force_flush(timeout_millis)

    try:
        exporter = TrackingExporter()
        provider = LoggerProvider(resource=Resource.create(resource_attributes))
        provider.add_log_record_processor(SimpleLogRecordProcessor(exporter))
        logger = provider.get_logger("postgresql-backup.shell", "1.0.0")
        now = time.time_ns()
        logger.emit(
            timestamp=now,
            observed_timestamp=now,
            severity_number=severity,
            severity_text=args.level.upper(),
            body=args.message,
            attributes=log_attributes,
        )
        succeeded = exporter.last_result is LogRecordExportResult.SUCCESS
        provider.shutdown()
        return 0 if succeeded else 1
    except Exception:  # O backup nunca deve falhar por indisponibilidade do Grafana.
        return 1


if __name__ == "__main__":
    sys.exit(main())
