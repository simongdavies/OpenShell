# syntax=docker/dockerfile:1.7

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

FROM rust:1.95-bookworm AS builder

ARG HYPERLIGHT_UNIKRAFT_COMMIT=3df47f64f99229e3cebef07b22ba948c69e1398c

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

RUN git init /src/hyperlight-unikraft \
    && git -C /src/hyperlight-unikraft remote add origin https://github.com/hyperlight-dev/hyperlight-unikraft.git \
    && git -C /src/hyperlight-unikraft fetch --depth 1 origin "${HYPERLIGHT_UNIKRAFT_COMMIT}" \
    && git -C /src/hyperlight-unikraft checkout --detach FETCH_HEAD \
    && test "$(git -C /src/hyperlight-unikraft rev-parse HEAD)" = "${HYPERLIGHT_UNIKRAFT_COMMIT}"

RUN cargo build \
    --locked \
    --release \
    --manifest-path /src/hyperlight-unikraft/Cargo.toml

RUN HLUK_CACHE_DIR=/tmp/hluk-cache \
      /src/hyperlight-unikraft/target/release/hluk init /tmp/python-shell \
        --template python-shell \
    && initrd="$(find /tmp/hluk-cache/rootfs -type f -name '*.cpio' -print -quit)" \
    && test -n "${initrd}" \
    && install -m 0444 "${initrd}" /tmp/python-shell.cpio

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 sandbox \
    && useradd --create-home --uid 10001 --gid 10001 --shell /bin/bash sandbox

COPY --from=builder /src/hyperlight-unikraft/target/release/hluk /usr/local/bin/hluk
COPY --from=builder /tmp/python-shell.cpio /opt/hluk/python-shell.cpio
COPY examples/hyperlight-policy-demo/guest.py /opt/demo/guest.py
COPY examples/hyperlight-policy-demo/run-demo.sh /opt/demo/run-demo.sh

RUN install -d -o root -g root -m 0755 /opt/demo/input \
    && install -d -o sandbox -g sandbox -m 0750 /opt/demo/output \
    && printf 'hyperlight unikraft policy demo\n' > /opt/demo/input/message.txt \
    && printf 'outer policy must block this file\n' > /opt/demo/outer-secret.txt \
    && chmod 0444 /opt/demo/guest.py \
    && chmod 0555 /opt/demo/run-demo.sh

USER sandbox
WORKDIR /home/sandbox
