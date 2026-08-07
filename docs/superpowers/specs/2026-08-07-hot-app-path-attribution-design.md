# Hot App Path Attribution Design

## Goal

Identify the individual `/app` files and directories that dominate OpenClaw Gateway, health, and CLI initialization under the current hybrid layout, without changing the live VMM configuration.

## Scope

This stage extends `scripts/32-profile-hybrid-paths.sh` with an optional `--top-paths N` output. It keeps the existing bucket-level results and adds ranked file paths for every traced command. It does not create images, install services, or change mount specs.

## Interface

```text
scripts/32-profile-hybrid-paths.sh \
  --state-loop DEV \
  --app-loop DEV \
  --runtime-loop DEV \
  --profile-image IMAGE \
  --expected-cache metadata \
  --top-paths 25 \
  --repeats 3 \
  --result-dir DIR
```

`--top-paths` accepts a positive integer and defaults to 25. Each command/run writes a tab-separated file with `syscall_ms`, `events`, and `path`, sorted by cumulative traced file-syscall duration. The JSON record also carries the same data under `top_paths`.

## Data flow

1. The existing profiler creates one fresh Pod/VM/container per repeat.
2. Existing `strace -e trace=%file` collection remains unchanged.
3. Before guest trace files are removed, a guest-side `awk` aggregation ranks paths by cumulative syscall duration.
4. The host converts the tab-separated output to JSON and writes both the JSON record and a human-readable `*-top.tsv` artifact.
5. Existing mount evidence, effective TOML, sandboxer hash, bucket aggregates, cleanup, and cold-start semantics remain unchanged.

## Error handling and safety

- Invalid `--top-paths` values fail before CRI resources are created.
- Empty trace output produces an empty `top_paths` array rather than invalid JSON.
- Guest trace files are still removed after aggregation; no large raw trace retention is introduced.
- The profiler continues to require `--expected-cache metadata` for the current experiment.
- This stage is attribution only; no service restart or configuration install is permitted.

## Acceptance criteria

- `bash -n scripts/32-profile-hybrid-paths.sh` passes.
- The profiler help documents `--top-paths`.
- A regression test verifies positive-value validation and JSON/TSV output wiring without contacting CRI.
- A later three-repeat live run has `rc=0` for all traced commands, complete provenance/mount evidence, and non-empty top-path artifacts for Gateway and health.
