#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: verify.sh <driver> <image> <fixture-host> <allowed-port> <inner-denied-port> <outer-denied-port>" >&2
  exit 2
fi

DRIVER=$1
IMAGE=$2
FIXTURE_HOST=$3
ALLOWED_PORT=$4
INNER_DENIED_PORT=$5
OUTER_DENIED_PORT=$6
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX_NAME=hluk-policy-demo
OPENSHELL="${OPENSHELL_BIN:-openshell}"
POLICY=$(mktemp)
OUTPUT=$(mktemp)
LOGS=$(mktemp)
EXIT_STATUS=$(mktemp)

cleanup() {
  "${OPENSHELL}" sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
  rm -f "${POLICY}" "${OUTPUT}" "${LOGS}" "${EXIT_STATUS}"
}
trap cleanup EXIT

uv run --no-project python "${ROOT}/examples/hyperlight-policy-demo/render_policy.py" \
  --template "${ROOT}/examples/hyperlight-policy-demo/policy.template.yaml" \
  --output "${POLICY}" \
  --fixture-host "${FIXTURE_HOST}" \
  --allowed-port "${ALLOWED_PORT}" \
  --inner-denied-port "${INNER_DENIED_PORT}"

set +e
"${OPENSHELL}" sandbox create \
  --name "${SANDBOX_NAME}" \
  --from "${IMAGE}" \
  --policy "${POLICY}" \
  --driver-config-json "$(case "${DRIVER}" in
    kubernetes) printf '%s' '{"kubernetes":{"pod":{"node_selector":{"hyperlight.dev/hypervisor":"kvm"}},"containers":{"agent":{"resources":{"requests":{"hyperlight.dev/hypervisor":"1"},"limits":{"hyperlight.dev/hypervisor":"1"}}}}}}' ;;
    docker) printf '%s' '{"docker":{"hypervisor_device":"kvm"}}' ;;
    podman) printf '%s' '{"podman":{"hypervisor_device":"kvm"}}' ;;
    *) echo "unsupported driver ${DRIVER}" >&2; exit 2 ;;
  esac)" \
  --no-auto-providers \
  --no-tty \
  -- /opt/demo/run-demo.sh "${FIXTURE_HOST}" "${ALLOWED_PORT}" "${INNER_DENIED_PORT}" "${OUTER_DENIED_PORT}" \
  2>&1 | tee "${OUTPUT}"
printf '%s\n' "${PIPESTATUS[0]}" >"${EXIT_STATUS}"
set -e
if [ "$(cat "${EXIT_STATUS}")" != "0" ]; then
  if [ "$(cat "${EXIT_STATUS}")" != "1" ]; then
    echo "sandbox create exited with unexpected status $(cat "${EXIT_STATUS}")" >&2
    exit 1
  fi
fi

for marker in \
  KVM_DEVICE_READY \
  OUTER_FILESYSTEM_DENIED \
  INNER_FILESYSTEM_DENIED \
  INNER_NETWORK_DENIED \
  OUTER_NETWORK_DENIED \
  FILESYSTEM_NETWORK_AND_TOOL_ALLOWED; do
  grep -F "${marker}" "${OUTPUT}" >/dev/null
done

echo "OPENSHELL_SANDBOX_IDENTIFIED=${SANDBOX_NAME}"

for _ in $(seq 1 40); do
  "${OPENSHELL}" logs "${SANDBOX_NAME}" --since 2m --source sandbox -n 500 >"${LOGS}" 2>&1 || true
  if grep -E "ALLOWED.*:${ALLOWED_PORT}|:${ALLOWED_PORT}.*ALLOWED" "${LOGS}" >/dev/null \
    && grep -E "DENIED.*:${OUTER_DENIED_PORT}|:${OUTER_DENIED_PORT}.*DENIED" "${LOGS}" >/dev/null; then
    break
  fi
  sleep 0.25
done

grep -E "ALLOWED.*:${ALLOWED_PORT}|:${ALLOWED_PORT}.*ALLOWED" "${LOGS}" >/dev/null
grep -E "DENIED.*:${OUTER_DENIED_PORT}|:${OUTER_DENIED_PORT}.*DENIED" "${LOGS}" >/dev/null
if grep -E "(ALLOWED|DENIED).*:${INNER_DENIED_PORT}|:${INNER_DENIED_PORT}.*(ALLOWED|DENIED)" "${LOGS}" >/dev/null; then
  echo "inner-denied origin reached the OpenShell network boundary" >&2
  exit 1
fi

printf '%s\n' \
  "OPENSHELL_ALLOWED_PORT=${ALLOWED_PORT}" \
  "OPENSHELL_OUTER_DENIED_PORT=${OUTER_DENIED_PORT}" \
  "INNER_DENIED_PORT_NOT_OBSERVED=${INNER_DENIED_PORT}"
