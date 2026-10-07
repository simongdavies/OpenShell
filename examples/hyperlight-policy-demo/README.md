# OpenShell + Hyperlight-Unikraft Policy Demo

This example runs ordinary Python, Bash, and a subprocess through
[`hyperlight-unikraft`](https://github.com/hyperlight-dev/hyperlight-unikraft)
commit `3df47f64f99229e3cebef07b22ba948c69e1398c` inside an OpenShell
Kubernetes sandbox on x86-64 Linux/KVM.

The OpenShell workload remains an ordinary Linux process. `openshell-sandbox`
applies Landlock, seccomp, non-root identity, and supervisor-mediated networking
to the `hluk` hosting process. `hluk` then starts a Hyperlight-Unikraft VM whose
hostfs and network host functions have their own narrower capabilities. A VM
escape therefore lands in an already constrained OpenShell workload process.

## Requirements

- x86-64 Linux with readable and writable `/dev/kvm`
- Docker with a Linux daemon
- `kind`, `kubectl`, `helm`, `mise`, and the repository development tools
- Sufficient host inotify capacity for kind
- Network access while building images and fetching the pinned Python-shell
  rootfs

The example fails when KVM or the Kubernetes device allocation is unavailable.
It never substitutes QEMU or another backend.

Linux security fix
[CVE-2026-53236](https://git.kernel.org/stable/c/3747de241a66ef2c7032d2cc2b826a47c5fa0f6a)
requires `CAP_NET_ADMIN` for TCP `SO_ATTACH_FILTER`. OpenShell remains
capability-free: its Kubernetes boundary rejects loopback/self-address peers
immediately after `accept`, before TLS or handshake state, instead of attaching
a classic socket filter. Kubernetes NetworkPolicy admits only supervisor Pods,
and mTLS still binds the exact sandbox, generation, and Pod identity.

The local Docker lane uses OpenShell's authenticated Unix boundary.

## Run

### Local Docker

From the repository root:

```shell
mise run example:hyperlight:local
```

This installs a fixed Hyperlight CDI specification and starts an ephemeral
Docker-backed OpenShell gateway.

### kind

Run the Kubernetes integration with:

```shell
mise run example:hyperlight:kvm
```

The command:

1. Builds `hluk` at the pinned commit and embeds its matching Python-shell
   rootfs in the workload image.
2. Builds the Hyperlight Kubernetes device plugin at pinned commit
   `fc71b4501d23977fcc54f7be144d884fc8210667`.
3. Creates an ephemeral kind node with `/dev/kvm` and enables containerd CDI.
4. Deploys OpenShell with resource admission enabled and an exact operator
   allowlist for `hyperlight.dev/hypervisor`.
5. Creates an OpenShell sandbox whose workload Pod receives the device.
6. Runs local HTTP fixtures and checks exact inner and outer policy evidence.
7. Removes the sandbox, cluster, and fixtures.

Expected evidence includes:

```text
KVM_DEVICE_READY
OUTER_FILESYSTEM_DENIED
FILESYSTEM_NETWORK_AND_TOOL_ALLOWED
INNER_FILESYSTEM_DENIED
INNER_NETWORK_DENIED
OUTER_NETWORK_DENIED
```

The network checks also require an OpenShell `ALLOWED` event for the approved
port, an OpenShell `DENIED` event for the outer-denied port, and no OpenShell
network event for the destination rejected by Unikraft before a host socket is
opened.

The local Docker and kind lanes use the same image, policy, fixture, and
assertions. Neither grants `CAP_NET_ADMIN` or privileged mode.

## Enforcement layers

| Check | Enforcement boundary |
|---|---|
| Pod receives `/dev/kvm` | Kubernetes device plugin and CDI after the Pod requests `hyperlight.dev/hypervisor: 1` |
| `hluk` reads the embedded rootfs and guest script | OpenShell filesystem policy |
| Guest reads `/input/message.txt` | OpenShell permits the host directory; Unikraft hostfs maps it read-only |
| Guest writes `/output/result.txt` | OpenShell permits the host directory; Unikraft hostfs maps it read-write |
| Guest executes `sh` as a subprocess | Unikraft Python-shell guest filesystem |
| Guest reads `/input` without a hostfs mount | Unikraft denies it before a host filesystem operation |
| Workload reads `/opt/demo/outer-secret.txt` | OpenShell Landlock policy denies it |
| Guest reaches the approved fixture | Both Unikraft and OpenShell allow it |
| Guest reaches `192.0.2.1` | Unikraft rejects the unapproved TEST-NET destination before OpenShell sees a connection |
| Guest reaches the outer-denied port | Unikraft permits the hostname; OpenShell denies the destination |

Removing the Unikraft allowlist does not bypass OpenShell. The outer-denied
request still runs with `--net-allow host.openshell.internal`; only OpenShell's
port-specific network policy rejects it.

## Operator approval

Kubernetes driver config remains disabled by default. The demo enables it and
keeps resource admission on:

```yaml
server:
  drivers:
    kubernetes:
      allowDriverConfig: true
      allowedExtendedResources:
        - hyperlight.dev/hypervisor
      resourceAdmission:
        enabled: true
```

The sandbox selects the KVM node and requests one device allocation:

```json
{
  "kubernetes": {
    "pod": {
      "node_selector": {
        "hyperlight.dev/hypervisor": "kvm"
      }
    },
    "containers": {
      "agent": {
        "resources": {
          "requests": {
            "hyperlight.dev/hypervisor": "1"
          },
          "limits": {
            "hyperlight.dev/hypervisor": "1"
          }
        }
      }
    }
  }
}
```

The allowlist approves only that exact extended resource. It does not approve
host paths, arbitrary devices, or other qualified resource names.

## Tests

Configuration and local-fixture tests:

```shell
mise run example:hyperlight:test
```

Real OpenShell + Kubernetes + KVM:

```shell
mise run example:hyperlight:kvm
```

Real local OpenShell + Docker + KVM:

```shell
mise run example:hyperlight:local
```

## Why not urunc

`urunc` can package a Hyperlight-Unikraft guest as an OCI workload, but selecting
it as an opaque Kubernetes `RuntimeClass` has not demonstrated OpenShell's
bootstrap, Landlock/seccomp qualification, boundary socket, or supervisor
mediation. This example runs `hluk` as the OpenShell-confined host process
instead, so OpenShell's existing outer policy remains observable and testable.

## Limitations

- This is a one-shot `hluk` tool-executor pattern, not yet a first-class
  OpenShell `IsolationBackend`.
- The device plugin and Hyperlight-Unikraft are pre-1.0 components. Both source
  revisions are pinned for reproducibility.
- The build downloads the pinned Python-shell rootfs. Mirror it for offline or
  hermetic deployments.
