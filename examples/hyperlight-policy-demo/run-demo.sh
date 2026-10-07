#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: run-demo.sh <fixture-host> <allowed-port> <inner-denied-port> <outer-denied-port>" >&2
  exit 2
fi

HOST_GATEWAY_IP=$1
ALLOWED_PORT=$2
INNER_DENIED_PORT=$3
OUTER_DENIED_PORT=$4
HLUK=/usr/local/bin/hluk
INITRD=/opt/hluk/python-shell.cpio
GUEST=/opt/demo/guest.py
OUTPUT_DIR=/opt/demo/output
LOG=$(mktemp)
SANITIZED_LOG=$(mktemp)

if [ ! -c /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "KVM device is not available to the sandbox" >&2
  exit 1
fi
echo "KVM_DEVICE_READY"

if { IFS= read -r _ < /opt/demo/outer-secret.txt; } 2>/dev/null; then
  echo "outer filesystem policy unexpectedly allowed /opt/demo/outer-secret.txt" >&2
  exit 1
fi
echo "OUTER_FILESYSTEM_DENIED"

if ! "${HLUK}" run \
  --initrd "${INITRD}" \
  --scratch-mb 256 \
  --env "DEMO_HOST=${HOST_GATEWAY_IP}" \
  --env "DEMO_ALLOWED_PORT=${ALLOWED_PORT}" \
  --env "DEMO_INNER_PORT=${INNER_DENIED_PORT}" \
  --env "DEMO_OUTER_PORT=${OUTER_DENIED_PORT}" \
  --mount /opt/demo/input:/input:ro \
  --mount /opt/demo/output:/output \
  --net-allow "${HOST_GATEWAY_IP}" \
  "${GUEST}" >"${LOG}" 2>&1; then
  tr -d '\000' <"${LOG}" >&2
  exit 1
fi

tr -d '\000' <"${LOG}" >"${SANITIZED_LOG}"
for marker in \
  INNER_FILESYSTEM_DENIED \
  INNER_NETWORK_DENIED \
  OUTER_NETWORK_DENIED \
  FILESYSTEM_NETWORK_AND_TOOL_ALLOWED; do
  if ! grep -Fx "${marker}" "${SANITIZED_LOG}" >/dev/null; then
    cat "${SANITIZED_LOG}" >&2
    exit 1
  fi
done

result=$(cat "${OUTPUT_DIR}/result.txt")
if [ "${result}" != "HYPERLIGHT UNIKRAFT POLICY DEMO|TOOL_OK|200" ]; then
  printf 'unexpected output result: %q\n' "${result}" >&2
  exit 1
fi

printf '%s\n' \
  INNER_FILESYSTEM_DENIED \
  INNER_NETWORK_DENIED \
  OUTER_NETWORK_DENIED \
  FILESYSTEM_NETWORK_AND_TOOL_ALLOWED

exit 0
