#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${OPENSHELL_HYPERLIGHT_IMAGE:-openshell/hyperlight-policy-demo:dev}"
PLUGIN_IMAGE=openshell/hyperlight-device-plugin:fc71b450
PLUGIN_COMMIT=fc71b4501d23977fcc54f7be144d884fc8210667
CLUSTER_NAME="openshell-hyperlight-$$"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
READY_FILE=$(mktemp)
FIXTURE_LOG=$(mktemp)
FIXTURE_PID=
CLUSTER_CREATED=0

cleanup() {
  if [ -n "${FIXTURE_PID}" ]; then
    kill "${FIXTURE_PID}" >/dev/null 2>&1 || true
    wait "${FIXTURE_PID}" >/dev/null 2>&1 || true
  fi
  if [ "${CLUSTER_CREATED}" = "1" ]; then
    if [ "${OPENSHELL_HYPERLIGHT_KEEP_CLUSTER:-0}" = "1" ]; then
      echo "Preserving debug cluster ${CLUSTER_NAME} (${KUBE_CONTEXT})." >&2
    else
      kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "${READY_FILE}" "${FIXTURE_LOG}"
}
trap cleanup EXIT

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: this example requires x86-64 Linux with KVM." >&2
  exit 2
fi
if [ ! -c /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "ERROR: readable and writable /dev/kvm is required; no fallback backend is used." >&2
  exit 2
fi
if [ "$(sysctl -n kernel.unprivileged_bpf_disabled 2>/dev/null || echo 2)" != "0" ]; then
  echo "ERROR: OpenShell's Kubernetes TCP boundary requires kernel.unprivileged_bpf_disabled=0." >&2
  echo "       Set it explicitly for this development host; the demo will not weaken the boundary." >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: a reachable Linux Docker daemon is required." >&2
  exit 2
fi
for command in kind kubectl helm; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: ${command} is required." >&2
    exit 2
  fi
done

docker build \
  --file "${ROOT}/examples/hyperlight-policy-demo/Dockerfile" \
  --tag "${IMAGE}" \
  "${ROOT}"
docker build \
  --tag "${PLUGIN_IMAGE}" \
  "https://github.com/hyperlight-dev/hyperlight-on-kubernetes.git#${PLUGIN_COMMIT}:device-plugin"

CLUSTER_CREATED=1
kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config "${ROOT}/examples/hyperlight-policy-demo/kind-config.yaml"

NODE=$(kind get nodes --name "${CLUSTER_NAME}" | head -n 1)
docker exec "${NODE}" sysctl -w kernel.unprivileged_bpf_disabled=0
docker exec "${NODE}" mkdir -p /var/run/cdi
docker exec "${NODE}" sed -i \
  '/\[plugins."io.containerd.grpc.v1.cri"\]/a\    enable_cdi = true\n    cdi_spec_dirs = ["/var/run/cdi", "/etc/cdi"]' \
  /etc/containerd/config.toml
docker exec "${NODE}" systemctl restart containerd
kubectl --context "${KUBE_CONTEXT}" wait \
  --for=condition=Ready "node/${NODE}" --timeout=120s

kind load docker-image "${IMAGE}" "${PLUGIN_IMAGE}" --name "${CLUSTER_NAME}"
kubectl --context "${KUBE_CONTEXT}" apply \
  -f "${ROOT}/examples/hyperlight-policy-demo/device-plugin.yaml"
if ! kubectl --context "${KUBE_CONTEXT}" -n hyperlight-system rollout status \
  daemonset/hyperlight-device-plugin --timeout=180s; then
  kubectl --context "${KUBE_CONTEXT}" -n hyperlight-system get pods -o wide >&2 || true
  kubectl --context "${KUBE_CONTEXT}" -n hyperlight-system describe \
    daemonset/hyperlight-device-plugin >&2 || true
  kubectl --context "${KUBE_CONTEXT}" -n hyperlight-system logs \
    daemonset/hyperlight-device-plugin >&2 || true
  kubectl --context "${KUBE_CONTEXT}" -n hyperlight-system logs \
    daemonset/hyperlight-device-plugin --previous >&2 || true
  exit 1
fi

capacity=
for _ in $(seq 1 60); do
  capacity=$(kubectl --context "${KUBE_CONTEXT}" get node "${NODE}" \
    -o go-template='{{ index .status.allocatable "hyperlight.dev/hypervisor" }}' \
    2>/dev/null || true)
  if [ -n "${capacity}" ] && [ "${capacity}" != "0" ]; then
    break
  fi
  sleep 1
done
if [ -z "${capacity}" ] || [ "${capacity}" = "0" ]; then
  echo "ERROR: Hyperlight device plugin did not advertise hyperlight.dev/hypervisor." >&2
  kubectl --context "${KUBE_CONTEXT}" -n hyperlight-system logs \
    daemonset/hyperlight-device-plugin >&2 || true
  exit 1
fi
HOST_GATEWAY_IP=$(docker network inspect kind \
  --format '{{(index .IPAM.Config 0).Gateway}}')
test -n "${HOST_GATEWAY_IP}"

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

read -r ALLOWED_PORT INNER_DENIED_PORT OUTER_DENIED_PORT < <(
  uv run --no-project python -c \
    'import json,sys; p=json.load(open(sys.argv[1])); print(p["allowed"], p["inner_denied"], p["outer_denied"])' \
    "${READY_FILE}"
)

cargo build -p openshell-cli --bin openshell

OPENSHELL_E2E_KUBE_CONTEXT="${KUBE_CONTEXT}" \
OPENSHELL_E2E_KUBE_BUILD_IMAGES=1 \
OPENSHELL_E2E_KUBE_EXTRA_VALUES="${ROOT}/examples/hyperlight-policy-demo/values.yaml" \
OPENSHELL_REGISTRY=openshell \
OPENSHELL_BIN="${ROOT}/target/debug/openshell" \
IMAGE_TAG=hyperlight-demo \
  "${ROOT}/e2e/with-kube-gateway.sh" \
  bash "${ROOT}/examples/hyperlight-policy-demo/verify.sh" \
    kubernetes "${IMAGE}" "${HOST_GATEWAY_IP}" \
      "${ALLOWED_PORT}" "${INNER_DENIED_PORT}" "${OUTER_DENIED_PORT}"
