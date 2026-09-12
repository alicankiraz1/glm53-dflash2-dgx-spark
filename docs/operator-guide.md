# Operator guide

This guide describes the supported operator flow for the four-node GLM-5.3
TP4 package. It assumes that the operator has authorized access to four DGX
Spark nodes and has reviewed the model and runtime licenses. Commands that can
change a node are plan-only until the operator supplies both `--apply` and the
digest printed by the current plan.

## 1. Prepare the control host

Use a clean checkout of this repository. The control host should provide Bash
3.2 or newer, Python 3.11 or newer, `ssh`, `ssh-keygen`, `rsync`, `git`, `awk`,
`curl`, and SHA-256 tooling. The source node additionally needs Docker, `hf`,
and the tools checked by the remote preflight.

The operator must provide two protected host-key files:

- the management `known_hosts` file named by `ssh.known_hosts_file`; and
- the direct-fabric `known_hosts` file named by
  `ssh.fabric_known_hosts_file`.

SSH must use key authentication with `BatchMode=yes`, strict host-key checking,
and no fallback to a global host-key file. The example configuration uses
documentation-only addresses and digest placeholders. Replace them with the
authorized inventory and the SHA-256 of each node's `/etc/machine-id` content,
computed after stripping its trailing newline:

```bash
tr -d '\n' </etc/machine-id | sha256sum | awk '{print $1}'
```

```bash
cp config/cluster.example.json config/cluster.json
${EDITOR:-vi} config/cluster.json
python3 tools/config_state.py validate \
  --config config/cluster.json \
  --lock config/reproduction.lock.json
```

The configuration validator requires exactly four ordered nodes, ranks 0
through 3, one source role, four node fabric addresses, unique aliases,
absolute remote roots, cache roots, and valid machine identity digests. Keep
the resulting `config/cluster.json` local; it is ignored by Git.

### Source package root and workers

The configured source `remote_root` must already contain the exact reviewed
package artifacts before `prepare` is applied. The remote preflight verifies
these files before bootstrap; the controller pipes the dispatcher over SSH but
does not upload a package checkout:

- `manifests/glm53-target-aa28e1f5.json` and
  `manifests/glm53-draft-7d74cdd8.json`;
- `runtime/Containerfile`, `runtime/patches/series.json`, and the locked patch;
- `tools/verify_hf_cache.py`, `tools/artifact_manifest.py`, and
  `tools/patch_series.py`.

For a committed shared release, run the following on the configured source
node, with the release owner supplying the authorized URL and commit:

```bash
: "${REPOSITORY_URL:?Set REPOSITORY_URL to the authorized repository URL}"
: "${PACKAGE_ROOT:?Set PACKAGE_ROOT to the configured source remote_root}"
: "${RELEASE_COMMIT:?Set RELEASE_COMMIT to the reviewed release commit}"
git clone "$REPOSITORY_URL" "$PACKAGE_ROOT"
git -C "$PACKAGE_ROOT" checkout --detach "$RELEASE_COMMIT"
test "$(git -C "$PACKAGE_ROOT" rev-parse HEAD)" = "$RELEASE_COMMIT"
```

Supply the environment values before running the commands on the source node.
Do not clone an older default branch that lacks the locked files. Do not copy a dirty checkout, credentials, or the entire
operator environment. A local candidate may be used only when the
reviewed file set is placed at `PACKAGE_ROOT` byte-for-byte and its plan-pinned
digests match.

On each worker, the configured `remote_root` and `hf_cache_root` must already
exist as plain directories. They should be empty of stale run state for a new
run; workers do not need a full repository checkout because the controller
transfers a run-scoped verification bundle. The source cache's parent and the
source/fabric `known_hosts` files must also already exist. Provision these
directories, keys, and network reachability separately; this package does not
automate privileged host setup.

## 2. Run the read-only doctor

Run doctor before preparation and again immediately before every apply. It
checks local executables, the protected management `known_hosts` file, all four
management aliases, remote node identity, storage, GPU/container prerequisites,
and fabric reachability.

```bash
./glm53-spark \
  --config config/cluster.json \
  --lock config/reproduction.lock.json \
  --state-root .state \
  doctor --json
```

Doctor never receives `--apply`. A failed doctor is an operational gate, not a
warning to be bypassed. Repair the underlying host-key, identity, storage,
runtime, or fabric condition and run it again.

## 3. Build and distribute the locked artifacts

Use a timestamped run ID with 32 lowercase hexadecimal characters after the
hyphen. The same run ID must be used for `prepare` and `launch`, because the
artifact and state paths are run-scoped.

```bash
RUN_ID="$(python3 -c 'import datetime, secrets; from tools.config_state import new_run_id; print(new_run_id(datetime.datetime.now(datetime.timezone.utc), secrets.token_bytes(16)))')"
PREPARE_PLAN="$(mktemp)"

./glm53-spark \
  --config config/cluster.json \
  --lock config/reproduction.lock.json \
  --state-root .state \
  prepare --run-id "$RUN_ID" | tee "$PREPARE_PLAN"

PREPARE_DIGEST="$(awk '$1 == "PLAN_SHA256:" { print $2 }' "$PREPARE_PLAN")"
test -n "$PREPARE_DIGEST"
```

Review the output for the config and lock digests, every plan-pinned source
file, the ordered patch series, model revisions, source node, worker targets,
and transfer destinations. Apply only that exact output:

```bash
./glm53-spark \
  --config config/cluster.json \
  --lock config/reproduction.lock.json \
  --state-root .state \
  --apply prepare \
  --run-id "$RUN_ID" \
  --plan-digest "$PREPARE_DIGEST" \
  --acknowledge-draft-license CC-BY-NC-ND-4.0
```

The explicit acknowledgement is required because the draft model is licensed
under Creative Commons Attribution-NonCommercial-NoDerivatives 4.0
International. Preparation performs a fresh doctor check, revalidates every
digest, builds the runtime image from the pinned base and patch, verifies model
manifests and blobs, then distributes complete artifacts with resumable
transfers. It does not publish model weights or a prebuilt image.

If an apply fails, preserve the run directory and its failure record. Review
the failed phase, repair the external condition, and rerun the same idempotent
plan only when the inputs and digest are unchanged. Generate a new plan after
any input, source file, configuration, or lock change.

## 4. Launch TP4

Create and inspect a launch plan after preparation has completed:

```bash
LAUNCH_PLAN="$(mktemp)"

./glm53-spark \
  --config config/cluster.json \
  --lock config/reproduction.lock.json \
  --state-root .state \
  launch --run-id "$RUN_ID" | tee "$LAUNCH_PLAN"

LAUNCH_DIGEST="$(awk '$1 == "PLAN_SHA256:" { print $2 }' "$LAUNCH_PLAN")"
test -n "$LAUNCH_DIGEST"
```

The launch plan records the four ranks, image identity, model snapshot paths,
ports, ownership labels, pre-launch services, and bounded readiness waits. The
controller verifies all ranks before the first mutation, prepares logs and
quiesces only the recorded owner services, confirms both ports are free, then
releases all four ranks and checks collective/API readiness.

```bash
./glm53-spark \
  --config config/cluster.json \
  --lock config/reproduction.lock.json \
  --state-root .state \
  --apply launch \
  --run-id "$RUN_ID" \
  --plan-digest "$LAUNCH_DIGEST"
```

If launch fails after mutation begins, the abort path stops run-owned
containers and attempts to restore the recorded pre-launch services. Treat a
failed launch as unresolved until `status` and an operator review establish
the actual state.

A complete Docker ID receipt remains usable for recovery even if the SSH
command reports failure. If the connection fails before any complete receipt
arrives, the controller cannot prove the created container's identity and
leaves it untouched. Inspect the node and preserve the run evidence before
retrying; do not bind an unknown container by editing the state record.

## 5. Inspect the recorded run

`status` is read-only and compares the run's config and lock digests with the
current files. It also checks run ownership, container state, serving model
identity, and generation health:

```bash
./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state status --run-id "$RUN_ID"

./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state logs --run-id "$RUN_ID" --rank 0
```

Use ranks `0`, `1`, `2`, or `3` with `logs`. The controller redacts common
credential-bearing log lines before printing them. `status` reports a contract
drift instead of silently treating a changed configuration as the original
run; mutation commands reject that drift.

## 6. Run validation suites

Validation never starts, stops, or reconfigures the service. It requires a
recorded run with status `ready`, matching config/lock digests, and a serving
identity that names the expected model. The suite output is written beneath
`results/validation/` and remains ignored unless an operator curates a
sanitized summary.

```bash
./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state validate --run-id "$RUN_ID" --suite smoke

./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state validate --run-id "$RUN_ID" --suite correctness

./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state validate --run-id "$RUN_ID" --suite needle

./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state validate --run-id "$RUN_ID" --suite benchmark
```

`all` runs the suites in the fixed order `smoke`, `correctness`, `needle`,
`benchmark`. A correctness failure is recorded as evidence; an infrastructure
failure stops later suites because they could not be measured reliably. The
result is evidence for the named run and profile, not a general hardware or
performance claim.

Request and suite budgets are independent. By default, one HTTP request may
run for 120 seconds in `smoke` and `correctness`, and 300 seconds in `needle`
and `benchmark`. Set `GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS` to a positive
integer to override that per-request bound. The whole-suite SSH watchdog is
controlled separately by `GLM53_VALIDATE_SSH_TIMEOUT_SECONDS`; when unset, its
suite budgets are 600, 900, 2400, and 5400 seconds for `smoke`, `correctness`,
`needle`, and `benchmark`, respectively. A deliberately smaller total-suite
budget may cut off a suite before its individual requests finish. Keep both
values explicit in any validation report.

## 7. Stop or restore

Generate a plan for `stop` or `rollback`, review the owner and recorded state,
then apply the exact digest. The commands preserve images, caches, models,
artifacts, and logs.

```bash
RECOVERY_PLAN="$(mktemp)"

./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state rollback --run-id "$RUN_ID" | tee "$RECOVERY_PLAN"

RECOVERY_DIGEST="$(awk '$1 == "PLAN_SHA256:" { print $2 }' "$RECOVERY_PLAN")"
test -n "$RECOVERY_DIGEST"

./glm53-spark --config config/cluster.json --lock config/reproduction.lock.json \
  --state-root .state --apply rollback --run-id "$RUN_ID" \
  --plan-digest "$RECOVERY_DIGEST"
```

Use `stop` when the intended end state is stopped. Use `rollback` when the
recorded pre-launch services must be restored. Neither operation removes an
unrelated container or deletes a cache.

Recorded container names and immutable IDs must both match. If a rank is
renamed or a different container occupies its recorded name, stop and rollback
reject the identity drift before changing any rank. Inspect and resolve the
drift before retrying the operation.

### Older run records

Current lifecycle records bind every rank to an immutable recorded
`container_id`. Older records without that field are deliberately rejected;
the controller never infers an ID from a container name or label. Preserve the
old state and evidence, inspect the corresponding services manually, and
resolve the prior run before starting a fresh run. Do not edit a JSON record to
bypass this gate.

## 8. Evidence and release review

Keep the following with any operator report:

| Field | Requirement |
| --- | --- |
| Source revision | Exact repository commit used for the run |
| Configuration identity | Sanitized config digest; never publish inventory |
| Reproduction identity | Exact lock digest and pinned model/runtime revisions |
| Profile | Locked profile name and served model name |
| Run identity | Run ID and validation ID |
| Result | Suite outcomes and artifact basenames |
| Provenance | `local-fixture`, `source-node`, or `historical-source-deployment` |

Do not publish raw logs, absolute paths, credentials, host names, machine IDs,
model weights, container archives, or deployment inventory. Historical evidence
must be labelled as historical source deployment evidence. It is not fresh
package qualification and must not be presented as a speedup or regression
claim without a controlled comparison.

See [`results/reference/README.md`](../results/reference/README.md) for the
sanitized curation rules and [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)
for the license boundary.
