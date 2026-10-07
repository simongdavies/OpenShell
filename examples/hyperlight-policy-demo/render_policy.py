#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import argparse
from pathlib import Path


def port(value: str) -> int:
    parsed = int(value)
    if not 1 <= parsed <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return parsed


def render(
    template: str, fixture_host: str, allowed_port: int, inner_denied_port: int
) -> str:
    if allowed_port == inner_denied_port:
        raise ValueError("fixture ports must be distinct")
    return (
        template.replace("@@FIXTURE_HOST@@", fixture_host)
        .replace("@@ALLOWED_PORT@@", str(allowed_port))
        .replace("@@INNER_DENIED_PORT@@", str(inner_denied_port))
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture-host", required=True)
    parser.add_argument("--allowed-port", type=port, required=True)
    parser.add_argument("--inner-denied-port", type=port, required=True)
    args = parser.parse_args()

    rendered = render(
        args.template.read_text(encoding="utf-8"),
        args.fixture_host,
        args.allowed_port,
        args.inner_denied_port,
    )
    args.output.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
