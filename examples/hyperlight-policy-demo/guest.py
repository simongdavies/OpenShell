# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OpenShell Authors

from __future__ import annotations

import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path


def request(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


host = os.environ["DEMO_HOST"]

with Path("/input/message.txt").open(encoding="utf-8") as source:
    message = source.read().strip().upper()

tool = subprocess.run(
    ["/bin/sh", "-c", "printf TOOL_OK"],
    check=True,
    capture_output=True,
    text=True,
).stdout

try:
    Path("/unapproved/secret.txt").read_text(encoding="utf-8")
except OSError:
    print("INNER_FILESYSTEM_DENIED")
else:
    raise RuntimeError("Unikraft unexpectedly exposed an unmounted host path")

try:
    request(f"http://192.0.2.1:{os.environ['DEMO_INNER_PORT']}/allowed")
except OSError:
    print("INNER_NETWORK_DENIED")
else:
    raise RuntimeError("Unikraft unexpectedly allowed an unapproved destination")

allowed_status = request(f"http://{host}:{os.environ['DEMO_ALLOWED_PORT']}/allowed")
if allowed_status != 200:
    raise RuntimeError(f"unexpected allowed fixture status {allowed_status}")

try:
    outer_status = request(f"http://{host}:{os.environ['DEMO_OUTER_PORT']}/allowed")
    if outer_status != 403:
        raise RuntimeError(f"unexpected outer-policy status {outer_status}")
except OSError:
    pass
print("OUTER_NETWORK_DENIED")

with Path("/output/result.txt").open("w", encoding="utf-8") as target:
    target.write(f"{message}|{tool}|{allowed_status}\n")

print("FILESYSTEM_NETWORK_AND_TOOL_ALLOWED")
