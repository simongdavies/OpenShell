#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${OPENSHELL_HYPERLIGHT_IMAGE:-openshell/hyperlight-policy-demo:dev}"
READY_FILE=$(mktemp)
FIXTURE_LOG=$(mktemp)
FIXTURE_PID=
CDI_FILE=/etc/cdi/openshell-hyperlight-demo.json
CDI_INSTALLED=0

cleanup() {
  if [ -n "${FIXTURE_PID}" ]; then
    kill "${FIXTURE_PID}" >/dev/null 2>&1 || true
    wait "${FIXTURE_PID}" >/dev/null 2>&1 || true
  fi
  if [ "${CDI_INSTALLED}" = "1" ]; then
    docker run --rm --volume /etc/cdi:/out alpine:3.19 \
      rm -f /out/openshell-hyperlight-demo.json >/dev/null 2>&1 || true
  fi
  rm -f "${READY_FILE}" "${FIXTURE_LOG}"
}
trap cleanup EXIT

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: this example requires x86-64 Linux." >&2
  exit 2
fi
if [ ! -c /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "ERROR: readable and writable /dev/kvm is required; no fallback is used." >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: a reachable Linux Docker daemon is required." >&2
  exit 2
fi
if [ -e "${CDI_FILE}" ]; then
  echo "ERROR: ${CDI_FILE} already exists; refusing to overwrite operator configuration." >&2
  exit 2
fi

docker build \
  --file "${ROOT}/examples/hyperlight-policy-demo/Dockerfile" \
  --tag "${IMAGE}" \
  "${ROOT}"

docker run --rm \
  --volume /etc/cdi:/out \
  --volume "${ROOT}/examples/hyperlight-policy-demo/hyperlight-cdi.json:/in/hyperlight.json:ro" \
  alpine:3.19 \
  sh -c 'cp /in/hyperlight.json /out/openshell-hyperlight-demo.json && chmod 0644 /out/openshell-hyperlight-demo.json'
CDI_INSTALLED=1

uv run --no-project python "${ROOT}/examples/hyperlight-policy-demo/fixture.py" \
  --ready-file "${READY_FILE}" >"${FIXTURE_LOG}" 2>&1 &
FIXTURE_PID=$!

for _ in $(seq 1 100); do
  if [ -s "${READY_FILE}" ]; then
    break
  fi
  if ! kill -0 "${FIXTURE_PID}" 2>/dev/null; then
    cat "${FIXTURE_LOG}" >&2
    exit 1
  fi
  sleep 0.05
done
test -s "${READY_FILE}"
HOST_GATEWAY_IP=$(docker network inspect bridge \
  --format '{{(index .IPAM.Config 0).Gateway}}')
test -n "${HOST_GATEWAY_IP}"

read -r ALLOWED_PORT INNER_DENIED_PORT OUTER_DENIED_PORT < <(
  uv run --no-project python -c \
    'import json,sys; p=json.load(open(sys.argv[1])); print(p["allowed"], p["inner_denied"], p["outer_denied"])' \
    "${READY_FILE}"
)

cargo build -p openshell-cli --bin openshell
docker tag openshell/supervisor:dev openshell/supervisor:hyperlight-demo
docker tag openshell/sandbox:dev openshell/sandbox:hyperlight-demo

OPENSHELL_E2E_DOCKER_HYPERVISOR_DEVICE=1 \
OPENSHELL_E2E_DOCKER_SANDBOX_IMAGE="${IMAGE}" \
OPENSHELL_E2E_DOCKER_SANDBOX_IMAGE_PULL_POLICY=never \
OPENSHELL_SUPERVISOR_IMAGE=openshell/supervisor:hyperlight-demo \
OPENSHELL_SANDBOX_RUNTIME_IMAGE=openshell/sandbox:hyperlight-demo \
SUPERVISOR_IMAGE=openshell/supervisor:hyperlight-demo \
SANDBOX_IMAGE=openshell/sandbox:hyperlight-demo \
OPENSHELL_BIN="${ROOT}/target/debug/openshell" \
  "${ROOT}/e2e/with-docker-gateway.sh" \
  bash "${ROOT}/examples/hyperlight-policy-demo/verify.sh" \
    docker "${IMAGE}" "${HOST_GATEWAY_IP}" \
      "${ALLOWED_PORT}" "${INNER_DENIED_PORT}" "${OUTER_DENIED_PORT}"
