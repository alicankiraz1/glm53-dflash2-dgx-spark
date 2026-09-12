# GLM-5.3-Flash NVFP4 + DFlash2 DGX Spark Package Design

## Purpose and fixed scope

This package will reproduce, operate, and validate GLM-5.3-Flash NVFP4 with a
DFlash2 draft model on exactly four NVIDIA DGX Spark nodes using tensor
parallelism 4. The four hosts are configurable, but four is a design invariant,
not a default for a generalized cluster manager.
131072 is the validated context ceiling.

The repository distributes orchestration source and documentation under
Apache License 2.0. It distributes neither model weights nor container images.
The target and draft models remain separately licensed upstream.

## Validated runtime profile

The immutable reproduction lock will pin the inputs needed to reproduce this
validated profile:

- Target model: `LibertAIDAI/GLM-5.3-Flash-NVFP4`.
- Draft model: `incoai/GLM-5.3-Flash-DFlash2`.
- Tensor parallelism: 4.
- Context ceiling: 131072 tokens.
- Maximum running requests: 4.
- DFlash2 block size: 8.
- Draft attention backend: FlashAttention 4 (FA4).
- Target attention implementation: TileLang DeepSeek Sparse Attention (DSA).
- KV cache data type: BF16.
- Radix cache: disabled.

The lock will also pin source revisions, image base references and digests,
patch digests, model revisions, file manifests, and runtime arguments. Local
cluster configuration selects hosts and paths without changing locked
reproduction inputs.

## User interface and internal boundaries

The top-level interface will be a macOS Bash 3.2-compatible executable named
`glm53-spark`. It will expose:

```text
glm53-spark doctor
glm53-spark prepare
glm53-spark launch
glm53-spark validate
glm53-spark status
glm53-spark logs
glm53-spark stop
glm53-spark rollback
```

Host orchestration remains in Bash. Standard-library Python utilities will
parse and validate JSON configuration, manage atomic state records, validate
API responses, run correctness checks, and summarize benchmarks. Python tools
will use top-level imports, explicit timeouts, validated inputs, and actionable
errors.

`config/cluster.json` will be machine-local and ignored by Git. A tracked
schema and example will define exactly four ordered nodes, one designated
source node, SSH aliases, remote artifact roots, and service ports. No sample
will contain real inventory. A tracked immutable reproduction lock will carry
artifact identities separately from inventory.

## Workflow

The intended operational flow is:

1. `doctor` performs read-only local, SSH, node identity, storage, GPU,
   fabric, container runtime, and prerequisite checks.
2. `prepare` reproduces the runtime image on the configured source node,
   downloads pinned model revisions there, verifies manifests and digests,
   and distributes verified artifacts to the other three nodes.
3. `launch` records a run, performs all preflight gates, stages all four ranks,
   and starts TP4 through a parallel two-phase sequence.
4. `validate` checks health, API behavior, correctness, long-context
   retrieval, and benchmark profiles against the active run.
5. `status` and `logs` provide read-only, run-scoped inspection with sanitized
   output.
6. `stop` performs an explicit, run-owned shutdown.
7. `rollback` restores the recorded pre-launch service state without deleting
   caches, images, models, or unrelated containers.

## Plan/apply safety model

Commands that can mutate a host will be plan-only by default. They will print
a deterministic action plan and exit without mutation. Execution requires
`--apply`, a successful fresh preflight, an exact configuration and lock
digest match, and run ownership checks. Read-only commands will reject
mutation flags.

Plans will identify every host, path, artifact digest, container name, port,
and expected owner before execution. A changed input invalidates the plan.
Partial failures stop progression and preserve evidence for safe diagnosis.
Only resumable, idempotent transfer steps may be retried.

The package will never perform automatic cleanup or mutate firewall, sudo, or
network configuration. It will not remove caches, model directories, images,
or containers it cannot prove belong to the active run.

## SSH and node identity

Remote access will require key-based SSH, `BatchMode=yes`,
`StrictHostKeyChecking=yes`, and an explicit project-managed `known_hosts`
file. Password prompts, host-key learning, agent forwarding, and permissive
fallbacks are forbidden.

Each phase will compare the configured logical node ID with a read-only remote
identity probe. The ordered four-node mapping and the source-node role must
match before any apply operation. Remote SSH invocations inside loops will
detach standard input so a session cannot consume the orchestration stream.

## Atomic state and provenance

Every operation will use a collision-resistant run ID and store provenance
under `.state/runs/<run-id>/`. State writes will use a temporary file in the
same directory, flush and close it, then atomically rename it into place.
Readers will reject incomplete, malformed, unknown-version, or digest-mismatched
state.

A run record will include:

- Configuration and reproduction-lock digests.
- Ordered rank-to-node mapping and source-node identity.
- Image, model, patch, and manifest identities.
- Planned and completed actions with timestamps and outcomes.
- Pre-launch service observations needed for rollback.
- Container ownership labels and active runtime arguments.
- Sanitized validation summaries and paths to detailed local artifacts.

Secrets, private keys, tokens, raw environment dumps, and unrestricted logs
will never enter state records.

## Reproducible preparation

The designated source node will build the runtime image locally from pinned
source revisions, a pinned base image digest, and reviewed patches. The build
will emit an immutable image digest and a software bill of materials or
equivalent package inventory. This repository will not publish a prebuilt
image.

Model downloads will resolve pinned revisions for both upstream repositories.
Preparation will construct and verify deterministic manifests containing
relative paths, sizes, and content digests before distribution. Transfers will
preserve partial artifacts and use manifest verification before promotion to
the final immutable path. A failed or interrupted transfer will not replace a
verified artifact.

## Parallel two-phase TP4 startup

TP4 startup requires all four ranks to rendezvous concurrently:

1. Phase one validates all rank commands, ownership labels, mounts, image and
   model digests, free resources, ports, and rendezvous reachability without
   creating containers.
2. Phase two stages all four rank launches, releases them in parallel, and
   waits for collective startup plus direct API health.

If any rank fails its startup gate, the orchestrator stops only containers
owned by the new run and restores the recorded pre-launch state. It preserves
logs and state for diagnosis.

## Validation and benchmark contract

Validation will be run-scoped and will include:

- Service health and model identity.
- Non-thinking API smoke behavior.
- Arithmetic, code, Turkish, and structured tool-call correctness.
- A 120K-token needle retrieval suite at 10%, 50%, and 90% insertion depths.
- Prefix and request-shape checks that do not rely on radix reuse.
- Throughput and latency benchmarks at concurrency 1 (C1) and concurrency 4
  (C4), with request parameters and raw measurements preserved.

Validation must distinguish infrastructure failure, timeout, malformed API
response, incorrect answer, and unsupported behavior. Generated validation
output remains untracked by default. Only sanitized, reviewed artifacts may be
promoted to `results/reference/`.

## Continuous integration

CI will run repository contracts, shell syntax and static checks, Python unit
tests, JSON/schema fixtures, deterministic plan snapshots, simulated
four-node lifecycle tests, secret scans, and documentation link checks.

CI has no DGX hardware and must not present mocked or simulated runs as live
hardware validation. Live qualification is a separate, explicit four-node
gate whose sanitized evidence may be curated into reference results.

## Known limitations

- 131072 is the validated context ceiling.
- A 256K TileLang prefill is impractical on this GB10 setup.
- The model exhibits thinking-always behavior; callers cannot rely on a
  non-thinking request to suppress all reasoning behavior.
- Hybrid KDA radix reuse is disabled because it is not validated for correct
  branched-prefix reuse in this profile.
- The package supports exactly four DGX Spark nodes with TP4 and does not
  provide elastic membership or alternative topology support.

## Exclusions

This repository does not include a router, tunneling service, unrelated model
deployment, destructive cache cleanup, model weights, or a prebuilt image. It
does not automate privileged host provisioning. Operators remain responsible
for prerequisite GPU drivers, container runtime installation, storage,
fabric, firewall, sudo policy, and network configuration.
