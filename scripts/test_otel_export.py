#!/usr/bin/env python3
"""Teste integrado local do exportador OTLP/HTTP Protobuf."""

from __future__ import annotations

import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from opentelemetry.proto.collector.logs.v1.logs_service_pb2 import (
    ExportLogsServiceRequest,
    ExportLogsServiceResponse,
)


def main() -> int:
    received: queue.Queue[tuple[str, str, str, bytes]] = queue.Queue(maxsize=1)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802 - assinatura definida pela stdlib
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            received.put(
                (
                    self.path,
                    self.headers.get("Content-Type", ""),
                    self.headers.get("Authorization", ""),
                    body,
                )
            )
            response = ExportLogsServiceResponse().SerializeToString()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-protobuf")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, format: str, *args: object) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        environment = os.environ.copy()
        environment.update(
            {
                "OTEL_EXPORTER_OTLP_ENDPOINT": (
                    f"http://127.0.0.1:{server.server_port}/otlp"
                ),
                "OTEL_EXPORTER_OTLP_HEADERS": (
                    "Authorization=Basic%20TEST_ONLY"
                ),
                "OTEL_EXPORTER_OTLP_TIMEOUT": "2",
                "GITHUB_ACTIONS": "true",
                "OTEL_SERVICE_VERSION": "test-version",
                "OTEL_JOB_NAME": "test-job",
            }
        )
        exporter = Path(__file__).with_name("otel_export.py")
        result = subprocess.run(
            [
                sys.executable,
                str(exporter),
                "--level",
                "ERROR",
                "--message",
                "Falha controlada",
                "--worker",
                "test-worker",
                "--operation",
                "test-export",
                "--status",
                "error",
                "--duration-ms",
                "12",
            ],
            env=environment,
            capture_output=True,
            check=False,
            timeout=10,
        )
        assert result.returncode == 0, "o exportador retornou falha"

        path, content_type, authorization, body = received.get(timeout=5)
        assert path == "/otlp/v1/logs", "caminho OTLP de logs incorreto"
        assert content_type == "application/x-protobuf", "encoding OTLP incorreto"
        assert authorization == "Basic TEST_ONLY", "header OTLP incorreto"

        request = ExportLogsServiceRequest()
        request.ParseFromString(body)
        resource_log = request.resource_logs[0]
        resource_attributes = {
            item.key: item.value.string_value
            for item in resource_log.resource.attributes
        }
        log_record = resource_log.scope_logs[0].log_records[0]
        log_attributes = {
            item.key: (
                item.value.int_value
                if item.value.HasField("int_value")
                else item.value.string_value
            )
            for item in log_record.attributes
        }

        assert resource_attributes["service.name"] == "postgresql-backup"
        assert resource_attributes["deployment.environment"] == "production"
        assert resource_attributes["service.version"] == "test-version"
        assert log_record.severity_text == "ERROR"
        assert log_record.body.string_value == "Falha controlada"
        assert log_attributes["job.name"] == "test-job"
        assert log_attributes["worker.name"] == "test-worker"
        assert log_attributes["operation"] == "test-export"
        assert log_attributes["status"] == "error"
        assert log_attributes["duration_ms"] == 12
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("Teste OTLP/HTTP Protobuf concluido com sucesso.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
