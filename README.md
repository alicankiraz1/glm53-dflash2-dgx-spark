# GLM-5.3-Flash NVFP4 + DFlash2 on DGX Spark

This repository packages a reproducible four-node TP4 deployment for
[`LibertAIDAI/GLM-5.3-Flash-NVFP4`](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4)
with the separately licensed
[`incoai/GLM-5.3-Flash-DFlash2`](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)
draft model. It contains the locked profile,
source-node artifact preparation, fail-closed lifecycle commands, and
read-only API and benchmark validation.

The package targets exactly four NVIDIA DGX Spark nodes. Host aliases,
machine identity digests, paths, and fabric addresses are supplied in a local
configuration file. The orchestration is intentionally not a general cluster
manager.

## Status and evidence boundary

The repository contains executable preparation, lifecycle, and validation
commands. Local tests and fixture runs validate software behavior; they do not
qualify DGX hardware, CUDA behavior, or a fresh four-node deployment.

No model weights or prebuilt container images are distributed. `prepare`
obtains the pinned models from their upstream repositories, builds the runtime
image on the configured source node, verifies the artifacts, and distributes
them to the other three nodes.

## Validated profile

The immutable profile is recorded in
[`config/reproduction.lock.json`](config/reproduction.lock.json). For the
historical source profile, 131072 is the validated context ceiling; this is
provenance for the locked profile, not a fresh hardware qualification.

| Setting | Locked value |
| --- | --- |
| Nodes / tensor parallelism | 4 nodes / TP4 |
| Context length | 131,072 tokens |
| Maximum running requests | 4 |
| DFlash2 block size | 8 |
| Draft attention | FA4 |
| Prefill and decode attention | TileLang |
| KV cache | BF16 |
| Radix cache | Disabled |
| Served model name | `glm-5.3-flash-nvfp4` |
| API port | 8002 |

The lock also pins model revisions and manifests, the base image digest, the
SGLang commit, the Containerfile digest, the ordered patch series, and the
patch digest. A changed input invalidates a previously printed plan digest.

## Requirements and bootstrap

Use Bash 3.2 or newer and Python 3.11 or newer. The control host needs `ssh`,
`ssh-keygen`, `rsync`, `git`, `awk`, `curl`, SHA-256 tooling, and an `hf` CLI
that can download the two locked model revisions. The source node needs Docker,
`hf`, and the tools checked by the remote preflight. The configured source
`remote_root` must already contain the exact reviewed package artifacts; the
controller sends the dispatcher over SSH but does not upload the package
checkout. All four nodes require key-based SSH with strict host-key checking,
the expected machine identity, storage, GPU/runtime prerequisites, and direct
fabric connectivity.

```bash
: "${REPOSITORY_URL:?Set REPOSITORY_URL to the authorized repository URL}"
git clone "$REPOSITORY_URL" glm53-dflash2-dgx-spark
cd glm53-dflash2-dgx-spark

cp config/cluster.example.json config/cluster.json
${EDITOR:-vi} config/cluster.json

python3 tools/config_state.py validate \
  --config config/cluster.json \
  --lock config/reproduction.lock.json
./glm53-spark doctor --json
```

The example uses documentation-only fabric addresses and synthetic machine
identity digests. Replace them with the authorized four-node inventory and the
protected management/fabric `known_hosts` files. `config/cluster.json` is
ignored by Git and must remain local.

The CLI defaults to `config/cluster.json`,
`config/reproduction.lock.json`, and `.state`. Use global `--config`, `--lock`,
and `--state-root` when those defaults do not apply.

## Workflow

All mutation-capable commands are plan-only by default. The apply form requires
the exact `PLAN_SHA256` printed by the current plan. Use one timestamped run ID
for preparation and launch:

```bash
RUN_ID="$(python3 -c 'import datetime, secrets; from tools.config_state import new_run_id; print(new_run_id(datetime.datetime.now(datetime.timezone.utc), secrets.token_bytes(16)))')"
PLAN_FILE="$(mktemp)"
./glm53-spark prepare --run-id "$RUN_ID" | tee "$PLAN_FILE"
PREPARE_DIGEST="$(awk '$1 == "PLAN_SHA256:" { print $2 }' "$PLAN_FILE")"
test -n "$PREPARE_DIGEST"
```

| Phase | Command | Behavior |
| --- | --- | --- |
| Preflight | `./glm53-spark doctor --json` | Read-only local, SSH, node, runtime, and fabric checks |
| Prepare | `./glm53-spark prepare --run-id "$RUN_ID"` | Plan image build, model acquisition, verification, and distribution |
| Launch | `./glm53-spark launch --run-id "$RUN_ID"` | Plan four-rank checks, ownership, ports, release, and readiness |
| Inspect | `./glm53-spark status --run-id "$RUN_ID"` | Read-only recorded-contract and serving check |
| Logs | `./glm53-spark logs --run-id "$RUN_ID" --rank 0` | Read-only redacted logs for one rank |
| Validate | `./glm53-spark validate --run-id "$RUN_ID" --suite all` | Read-only smoke, correctness, needle, and benchmark suites |
| Stop | `./glm53-spark stop --run-id "$RUN_ID"` | Plan a run-owned shutdown |
| Rollback | `./glm53-spark rollback --run-id "$RUN_ID"` | Plan restoration of the recorded pre-launch state |

For `prepare`, `launch`, `stop`, and `rollback`, apply only after reviewing
the plan and passing `--apply` with its exact `--plan-digest`. `prepare` also
requires `--acknowledge-draft-license CC-BY-NC-ND-4.0`; its upstream license is
the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International
license. The complete digest capture, apply, failure recovery, timeout, and
rollback procedure is in the [operator guide](docs/operator-guide.md).

## Historical reference: 2026-08-28 source deployment

The curated JSON below records historical source-deployment evidence for the
locked profile. It is not current package qualification, hardware acceptance,
or a speedup claim.

| Evidence | Historical result | Artifact |
| --- | --- | --- |
| 120K needle retrieval at three depths | 0 reported failures | [`historical-2026-08-28-c4.json`](results/reference/historical-2026-08-28-c4.json) |
| C1 median decode | 33.37 tokens/s | Same historical summary; no comparison claim |
| C4 median aggregate decode | 70.43 tokens/s | Same historical summary; no comparison claim |

See the [reference-artifact policy](results/reference/README.md) for the
provenance and sanitization rules. Raw artifacts remain outside this package;
the curated record contains only basenames and SHA-256 values.

## Limitations

- Exactly four nodes and TP4 are supported; arbitrary cluster sizes are out of
  scope.
- `doctor`, local tests, and fixture validation do not prove live hardware or
  future rebuild behavior.
- The model exhibits thinking-always behavior; a non-thinking request does not
  guarantee suppression of all reasoning behavior.
- Radix caching remains disabled because hybrid KDA branched-prefix reuse was
  not validated as correct for this profile.
- `validate` is read-only but writes ignored run-scoped evidence under
  `results/validation/`.
- Model weights, prebuilt images, credentials, host inventory, machine IDs, and
  private keys must be obtained or supplied outside this repository.

## Licensing

Original repository code is licensed under the Apache License 2.0. The target
model is separately licensed under the MIT License. The draft model is a
separately licensed Creative Commons Attribution-NonCommercial-NoDerivatives
4.0 International dependency with non-commercial/no-derivatives limits; its
weights are not redistributed or modified here.

The runtime patch is derived from SGLang and remains subject to the Apache
License 2.0 and attribution requirements. Components assembled into the
upstream base image retain their own terms. See [`NOTICE`](NOTICE) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Project documents

- [Operator guide](docs/operator-guide.md)
- [Approved design](docs/design.md)
- [Implementation plan](docs/superpowers/plans/2026-08-28-glm53-dflash2-dgx-spark-package.md)
- [Reference-artifact policy](results/reference/README.md)
- [Security policy](SECURITY.md)
- [Contributing guide](CONTRIBUTING.md)

The repository code is licensed under the [Apache License 2.0](LICENSE).
