#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import argparse
import json
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RESPONSE = b'{"fixture":"openshell-hyperlight","status":"ok"}\n'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/allowed":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(RESPONSE)))
        self.end_headers()
        self.wfile.write(RESPONSE)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def start_servers() -> list[ThreadingHTTPServer]:
    return [ThreadingHTTPServer(("0.0.0.0", 0), Handler) for _ in range(3)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()

    servers = start_servers()
    threads = [
        threading.Thread(target=server.serve_forever, daemon=True) for server in servers
    ]
    for thread in threads:
        thread.start()

    args.ready_file.write_text(
        json.dumps(
            {
                "allowed": servers[0].server_port,
                "inner_denied": servers[1].server_port,
                "outer_denied": servers[2].server_port,
            }
        ),
        encoding="utf-8",
    )

    stopped = threading.Event()

    def stop(_signal: int, _frame: object) -> None:
        stopped.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    stopped.wait()
    for server in servers:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
