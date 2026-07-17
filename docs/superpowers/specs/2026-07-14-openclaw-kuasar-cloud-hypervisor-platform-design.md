# OpenClaw on Kuasar and Cloud Hypervisor: Platform Design

Date: 2026-07-14

## 1. Goal

Build a small, repeatable experiment platform that runs an OpenClaw Gateway
through containerd, Kuasar's MicroVM sandboxer, and Cloud Hypervisor. The next
project review must demonstrate the complete path, not only a host-native
OpenClaw process or a plain runc container.

The target execution path is:

```text
operator CLI
  -> crictl / containerd CRI
  -> Kuasar vmm-sandboxer
  -> Cloud Hypervisor microVM
  -> guest kernel and vmm-task
  -> OpenClaw Gateway container
```

The platform must prove that OpenClaw can complete a real Agent task, expose
the active runtime path, collect useful logs, and remove all resources.

## 2. Current Baseline

The host-native application baseline is complete:

- OpenClaw 2026.6.11 is installed with Node.js 24.18.0.
- The user systemd Gateway service is enabled and running.
- Deep status reports the Gateway as reachable and the event loop as healthy.
- One Agent and a configured model session are present.

The container and sandbox path is not yet complete:

- The OpenClaw container image has not been built.
- The current user cannot access the Docker socket.
- `crictl` is not yet configured for the intended containerd CRI endpoint.
- Kuasar, `vmm-sandboxer`, and Cloud Hypervisor are not installed.

## 3. Scope

### In scope

- A reproducible, version-pinned OpenClaw image without embedded credentials.
- A plain containerd/runc smoke test for the same image.
- A time-boxed Kuasar integration smoke test.
- Kuasar MicroVM execution using Cloud Hypervisor and KVM.
- A shell-based platform with `deploy`, `status`, `logs`, `demo`, and `delete`.
- Evidence collection and a small runc-versus-MicroVM comparison.

### Out of scope

- Kubernetes, a web control plane, scheduling, multi-node operation, and
  multi-tenancy.
- Production-grade high availability, autoscaling, accounting, or secret
  management.
- A rigorous performance benchmark suitable for publication.
- VMMs other than Cloud Hypervisor.

## 4. Approach

Use a time-boxed layered approach. Plain runc and the Kuasar runc sandboxer are
diagnostic gates, while Kuasar VMM plus Cloud Hypervisor is the mandatory
delivery target.

This approach is preferred over a direct jump to VMM because it isolates image,
CRI, Kuasar integration, guest networking, and VMM failures. It is preferred
over an unrestricted sequential approach because intermediate runc work cannot
consume the schedule needed for the mandatory MicroVM result.

## 5. Architecture

```text
openclaw-platform
  +-- deploy
  +-- status
  +-- logs
  +-- demo
  +-- delete
         |
         v
       crictl
         | CRI
         v
     containerd
         | explicitly selected Kuasar VMM handler
         v
  Kuasar vmm-sandboxer
         |
         v
  Cloud Hypervisor microVM
         | guest kernel + vmm-task
         v
  OpenClaw Gateway container
```

The design has four boundaries:

1. **Control layer:** lifecycle commands, state reconciliation, and clear exit
   status.
2. **Runtime layer:** containerd, the registered Kuasar VMM handler,
   `vmm-sandboxer`, Cloud Hypervisor, and KVM.
3. **Application layer:** the pinned OpenClaw image and a dedicated persistent
   data directory.
4. **Observation layer:** CRI inspection, runtime processes, health probes,
   logs, timings, and evidence bundles.

The final `deploy` command requires an explicitly configured Kuasar VMM handler.
It must fail if the handler is absent or unusable and must never silently fall
back to plain runc. The exact handler string is read from the installed
containerd configuration rather than guessed or hard-coded before installation.

## 6. Image and Data Design

The experiment image installs the pinned OpenClaw 2026.6.11 release on a pinned
Node.js 24 base. The build records the image digest. The image contains no API
keys, provider tokens, Gateway credentials, or host session data.

OpenClaw configuration and writable state use a dedicated host directory with
restrictive permissions. That directory is mounted into the workload at
runtime. It is initialized either through interactive onboarding or by an
explicitly approved copy from the existing host configuration. It is never
stored in the repository or included in diagnostics.

The host-native Gateway remains a comparison baseline. The containerized
Gateway uses its own configuration and data directory. Platform health and demo
commands execute inside the workload through CRI, so the first release does not
need to expose the Control UI on a host network port. Outbound guest networking
and DNS remain mandatory because the Agent must contact its configured model
provider.

## 7. Platform Commands

### `deploy`

1. Verify containerd, the intended CRI socket, `/dev/kvm`, Kuasar services,
   Cloud Hypervisor, guest kernel/rootfs artifacts, image presence, and the
   explicit VMM handler.
2. Generate and validate CRI pod and container specifications.
3. Create the pod sandbox and OpenClaw container with `crictl`.
4. Wait for the Gateway readiness probe.
5. Confirm that the sandbox has a corresponding Cloud Hypervisor process.
6. Atomically store non-secret runtime state under `.state/`.

### `status`

Reconcile saved identifiers with actual CRI state, then report:

```text
containerd CRI       PASS|FAIL
Kuasar vmm-sandboxer PASS|FAIL
Cloud Hypervisor VM  PASS|FAIL
OpenClaw container   PASS|FAIL
Gateway health       PASS|FAIL
runtime handler      <registered Kuasar VMM handler>
```

It also prints pod and container IDs, Cloud Hypervisor PID, image digest,
runtime duration, and guest addressing when available.

### `logs`

Collect and label OpenClaw container logs, Kuasar `vmm-sandboxer` logs, and
Cloud Hypervisor or guest boot logs associated with the current sandbox.

### `demo`

Use `crictl exec` to invoke OpenClaw inside the workload and run a fixed task:

```text
Read the current runtime environment and produce a short status report.
```

Print the response, selected model, elapsed time, runtime handler, and Cloud
Hypervisor PID. This proves both Agent behavior and runtime placement without
requiring an externally exposed Dashboard.

### `delete`

Stop and remove the container, then stop and remove the pod sandbox. Confirm
that associated Cloud Hypervisor processes disappear. The operation is
idempotent and succeeds when the workload is already absent.

## 8. Local State and Diagnostics

`.state/` stores only non-secret identifiers and metadata:

- pod and container IDs;
- sandbox and handler names;
- image name and digest;
- deployment and readiness timestamps;
- Cloud Hypervisor PID discovered for the sandbox.

Failure diagnostics are written under `.artifacts/` and include CRI inspect
output, container logs, Kuasar service logs, Cloud Hypervisor logs, and component
versions. Collection filters known secret fields and never copies the OpenClaw
configuration directory.

Both directories are local experiment output and must be ignored by version
control.

## 9. Error Handling

- `deploy` treats creation as a transaction. On failure it stops subsequent
  steps and removes resources created by that invocation.
- Diagnostic output is captured before automatic rollback.
- Stale IDs are reconciled against CRI; saved state alone is never considered
  proof that a workload is running.
- A missing VMM handler, stopped Kuasar service, unavailable KVM device, missing
  guest artifact, or failed Gateway probe produces a non-zero exit status.
- Containerd and Kuasar configuration files are backed up before modification.
- Host package installation, system configuration, and service restart require
  explicit approval before execution.
- The VMM deployment never falls back to ordinary runc.

## 10. Delivery Gates

### Gate 1: Image and plain runc

The pinned OpenClaw image starts through containerd/runc, reports a healthy
Gateway, and completes the fixed Agent task.

### Gate 2: Kuasar integration

A minimal known-good image can be created and deleted through containerd and a
Kuasar sandboxer. This gate is limited to 10-15 percent of the remaining
schedule. Its purpose is interface diagnosis, not a polished deliverable.

### Gate 3: Cloud Hypervisor smoke test

A minimal image runs inside a Kuasar-managed Cloud Hypervisor microVM with
working KVM, guest boot, outbound network, DNS, image access, and cleanup.

### Gate 4: OpenClaw MicroVM

The same OpenClaw image from Gate 1 runs through the Kuasar VMM handler and
completes the fixed Agent task.

### Gate 5: Repeatable platform

Three consecutive `deploy -> demo -> delete` cycles succeed without leaving a
CRI container, pod sandbox, or Cloud Hypervisor process.

## 11. Acceptance Evidence

The final review requires all of the following:

1. CRI inspection shows the explicitly selected Kuasar VMM handler.
2. Kuasar logs associate the current sandbox ID with `vmm-sandboxer`.
3. A Cloud Hypervisor process is associated with the current sandbox.
4. Guest boot output or workload `uname` demonstrates execution in the
   microVM guest rather than the host kernel path.
5. The OpenClaw Gateway is healthy and completes the fixed Agent task.
6. After `delete`, the CRI resources and associated Cloud Hypervisor process no
   longer exist.

The presentation also includes a compact comparison between ordinary runc and
Cloud Hypervisor: cold deployment time, first Agent response time, host memory
increase, and isolation mechanism. The comparison is observational and uses
the same image and task for both paths.

## 12. Demonstration Sequence

```text
openclaw-platform deploy
openclaw-platform status
openclaw-platform demo
openclaw-platform logs
openclaw-platform delete
openclaw-platform status
```

The first status must prove every runtime layer. The demo must show a real Agent
response. The final status must prove complete resource reclamation.

## 13. Key Risks and Mitigations

- **containerd and Sandbox API compatibility:** identify exact installed
  versions and supported Kuasar integration before changing configuration.
- **Guest artifacts:** build or obtain the kernel and root filesystem using a
  version-matched Kuasar procedure and record their checksums.
- **KVM permissions:** verify access from the actual `vmm-sandboxer` service
  account, not only the interactive shell.
- **Guest networking:** prove network and DNS with a minimal image before
  diagnosing OpenClaw provider connectivity.
- **Secret handling:** use a dedicated runtime-mounted directory, restrictive
  permissions, redacted diagnostics, and no repository copies.
- **Schedule pressure:** time-box non-target runc integration and prioritize the
  mandatory Cloud Hypervisor path once each diagnostic gate has yielded enough
  evidence.

