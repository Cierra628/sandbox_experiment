# OpenClaw on Kuasar/containerd Design

## Goal

Build a minimal experiment platform that can run OpenClaw Gateway as a
containerd workload and then compare plain runc with Kuasar-backed sandbox
runtimes.

## Scope

This first version focuses on a single-node experiment. It does not install
Kubernetes, expose a public service, or automate privileged system changes.

The platform should make these questions easy to answer:

- Can OpenClaw run as a containerized long-running agent workload?
- Can the same workload run through containerd CRI using a Kuasar runtime
  handler?
- What changes when moving from plain runc to Kuasar runc and then to a
  stronger sandbox such as VMM?

## Architecture

The experiment keeps containerd as the upper runtime interface. Kuasar is placed
below containerd as the sandbox runtime layer. OpenClaw is treated as an OCI
image and launched through CRI-compatible pod and container specs.

```text
scripts / future CLI
        -> crictl
        -> containerd CRI plugin
        -> runtime handler: runc or Kuasar
        -> OpenClaw Gateway container
```

## Components

### Documentation

`README.md` gives the operator the short path through the experiment.

`docs/superpowers/specs/2026-07-09-openclaw-kuasar-design.md` records the design
for this first iteration.

`docs/superpowers/plans/2026-07-09-openclaw-kuasar-platform.md` records the
implementation plan.

### Image Build Context

`images/openclaw/` holds a local image build context. The first version expects
the OpenClaw source to be provided locally or copied in by a later script. The
image should run Gateway as the main process.

### Containerd CRI Specs

`containerd/openclaw-pod.json` and `containerd/openclaw-container.json` describe
the pod sandbox and container for `crictl`.

The specs default to a local image name:

```text
localhost/openclaw-gateway:experiment
```

### Scripts

Scripts are small and inspectable:

- `00-check-host.sh` checks host prerequisites.
- `01-prepare-openclaw-image.sh` creates a placeholder image context.
- `02-build-openclaw-image.sh` builds the image with `nerdctl`, `docker`, or
  `podman`.
- `03-generate-cri-specs.sh` writes CRI JSON specs.
- `04-run-with-crictl.sh` prints the exact `crictl` sequence for a selected
  runtime handler and optionally executes it.

## Runtime Strategy

The first runtime target is plain containerd/runc. This establishes that the
OpenClaw image and CRI specs are valid.

The second runtime target is Kuasar runc sandboxer. This validates that
containerd can route the same workload through a Kuasar runtime handler while
keeping application assumptions stable.

The third runtime target is Kuasar VMM or another stronger sandbox. This is the
interesting security experiment for an agent workload, but it should only be
attempted after the first two stages work.

## Data and Configuration

OpenClaw state should be mounted at:

```text
/data/openclaw
```

The host-side directory defaults to:

```text
/tmp/openclaw-kuasar-data
```

Secrets such as model API keys must not be committed. The scripts should read
environment variables or use a local, ignored env file in a later iteration.

## Error Handling

Scripts must fail fast on missing required tools and print the command the
operator should run next. Scripts must not silently install packages, edit
`/etc/containerd/config.toml`, or start system services.

## Verification

This iteration is verified by:

- Checking that all planned files exist.
- Running shell syntax checks for all scripts.
- Generating CRI specs successfully.

Future runtime verification should include:

- `crictl runp` creates a pod sandbox.
- `crictl create` creates the OpenClaw container.
- `crictl start` starts Gateway.
- `crictl logs` shows Gateway startup logs.
- The same image and specs work with the selected Kuasar runtime handler.

