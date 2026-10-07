# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import json
import threading
import urllib.request
from pathlib import Path

import pytest
import yaml
from fixture import RESPONSE, start_servers
from render_policy import render

EXAMPLE = Path(__file__).parent


def test_policy_preserves_outer_and_inner_boundaries() -> None:
    policy = yaml.safe_load(
        render(
            (EXAMPLE / "policy.template.yaml").read_text(encoding="utf-8"),
            "172.20.0.1",
            18081,
            18082,
        )
    )

    assert policy["filesystem_policy"] == {
        "include_workdir": False,
        "read_only": [
            "/bin",
            "/lib",
            "/lib64",
            "/proc",
            "/usr",
            "/etc",
            "/opt/demo/guest.py",
            "/opt/demo/input",
            "/opt/demo/run-demo.sh",
            "/opt/hluk/python-shell.cpio",
        ],
        "read_write": [
            "/dev/kvm",
            "/dev/null",
            "/dev/urandom",
            "/opt/demo/output",
            "/tmp",
        ],
    }
    assert policy["network_policies"]["hyperlight_fixture"]["binaries"] == [
        {"path": "/usr/local/bin/hluk"}
    ]
    assert [
        endpoint["port"]
        for endpoint in policy["network_policies"]["hyperlight_fixture"]["endpoints"]
    ] == [18081, 18082]


def test_policy_rejects_reused_fixture_port() -> None:
    with pytest.raises(ValueError, match="fixture ports must be distinct"):
        render("unused", "172.20.0.1", 18081, 18081)


def test_workload_pins_hyperlight_unikraft() -> None:
    dockerfile = (EXAMPLE / "Dockerfile").read_text(encoding="utf-8")

    assert "3df47f64f99229e3cebef07b22ba948c69e1398c" in dockerfile
    assert "python-shell" in dockerfile
    assert "/usr/local/bin/hluk" in dockerfile


def test_kubernetes_device_path_is_explicit_and_admitted() -> None:
    kind = yaml.safe_load((EXAMPLE / "kind-config.yaml").read_text(encoding="utf-8"))
    values = yaml.safe_load((EXAMPLE / "values.yaml").read_text(encoding="utf-8"))
    device_plugin = list(
        yaml.safe_load_all((EXAMPLE / "device-plugin.yaml").read_text(encoding="utf-8"))
    )[-1]

    assert kind["nodes"][0]["extraMounts"] == [
        {"hostPath": "/dev/kvm", "containerPath": "/dev/kvm"}
    ]
    assert values["server"]["drivers"]["kubernetes"] == {
        "allowDriverConfig": True,
        "allowedExtendedResources": ["hyperlight.dev/hypervisor"],
        "resourceAdmission": {"enabled": True},
    }
    assert device_plugin["spec"]["template"]["spec"]["containers"][0]["env"] == [
        {"name": "DEVICE_COUNT", "value": "32"},
        {"name": "DEVICE_UID", "value": "10001"},
        {"name": "DEVICE_GID", "value": "10001"},
    ]


def test_demo_pins_device_plugin_source() -> None:
    demo = (EXAMPLE / "demo.sh").read_text(encoding="utf-8")

    assert "fc71b4501d23977fcc54f7be144d884fc8210667" in demo
    assert "hyperlight.dev/hypervisor" in demo


def test_runner_asserts_required_security_evidence() -> None:
    runner = (EXAMPLE / "run-demo.sh").read_text(encoding="utf-8")

    for evidence in [
        "KVM_DEVICE_READY",
        "FILESYSTEM_NETWORK_AND_TOOL_ALLOWED",
        "INNER_FILESYSTEM_DENIED",
        "INNER_NETWORK_DENIED",
        "OUTER_FILESYSTEM_DENIED",
        "OUTER_NETWORK_DENIED",
        "outer-secret.txt",
    ]:
        assert evidence in runner


def test_fixture_serves_all_three_origins() -> None:
    servers = start_servers()
    threads = [
        threading.Thread(target=server.serve_forever, daemon=True) for server in servers
    ]
    for thread in threads:
        thread.start()
    try:
        responses = [
            urllib.request.urlopen(
                f"http://127.0.0.1:{server.server_port}/allowed", timeout=2
            ).read()
            for server in servers
        ]
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()

    assert responses == [RESPONSE, RESPONSE, RESPONSE]


def test_fixture_response_is_exact_json() -> None:
    assert json.loads(RESPONSE) == {
        "fixture": "openshell-hyperlight",
        "status": "ok",
    }
