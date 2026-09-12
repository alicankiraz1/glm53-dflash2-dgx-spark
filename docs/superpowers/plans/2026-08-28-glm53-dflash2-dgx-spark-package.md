# GLM-5.3-Flash NVFP4 + DFlash2 DGX Spark Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a reproducible, fail-closed package for deploying and
validating GLM-5.3-Flash NVFP4 with DFlash2 on exactly four configurable
NVIDIA DGX Spark nodes using tensor parallelism 4.

**Architecture:** A macOS Bash 3.2-compatible `glm53-spark` command owns host
orchestration, while standard-library Python modules validate JSON, atomic
state, manifests, API behavior, and benchmark results. Machine-local inventory
is separated from an immutable reproduction lock, and every mutation is a
reviewable plan unless `--apply` is explicitly supplied.

**Tech Stack:** macOS Bash 3.2, Python standard library, JSON, SSH, Docker or
an OCI-compatible runtime, GitHub Actions.

## Global Constraints

- All repository prose and code comments are English.
- Repository code license: Apache-2.0.
- Model weights and container images are never committed.
- Target model `LibertAIDAI/GLM-5.3-Flash-NVFP4` is separately MIT licensed.
- Draft model `incoai/GLM-5.3-Flash-DFlash2` is separately CC BY-NC-ND 4.0
  licensed and must be described as non-commercial/research-evaluation only.
  License summaries are informational and are not legal advice.
- The repository remains private.
- Support exactly four configurable DGX Spark nodes with TP4; do not
  generalize to arbitrary clusters.
- Host orchestration must remain compatible with macOS Bash 3.2.
- Python tools use the standard library only.
- Runtime mutations are dry-run/plan by default and require `--apply`.
- The validated profile is 131072 context, max 4 running requests, DFlash2
  block 8, FA4 draft attention, TileLang DSA, BF16 KV cache, and radix cache
  disabled.
- No router, tunneling service, unrelated model deployment, destructive cache
  cleanup, prebuilt image, or model weights belong in this repository.
- Never include personal IPs, hostnames, usernames, passwords, tokens, local
  runtime state, full raw reasoning traces, or old repository history.
- Strict key-based SSH and pinned `known_hosts` are mandatory.
- No automatic cleanup or firewall, sudo, or network mutation is authorized.
- Every executable change records TDD RED/GREEN evidence before its commit.
- Every task ends with focused tests, syntax checks, `git diff --check`, and a
  secret/inventory self-review.

## Planned file responsibilities

- `glm53-spark`: stable command dispatcher and global option parser.
- `lib/common.sh`: Bash 3.2-safe diagnostics, plan/apply gates, command
  execution, SSH option construction, and run ownership helpers.
- `lib/config.sh`: shell bridge to validated configuration and lock JSON.
- `lib/doctor.sh`: read-only local and four-node prerequisite checks.
- `lib/prepare.sh`: source-node build, model acquisition, manifest
  verification, and resumable distribution orchestration.
- `lib/lifecycle.sh`: parallel two-phase launch, status, logs, stop, and
  rollback orchestration.
- `lib/validate.sh`: active-run validation and benchmark orchestration.
- `config/cluster.schema.json`: fixed four-node inventory contract.
- `config/cluster.example.json`: synthetic, non-routable example inventory.
- `config/reproduction.lock.json`: immutable model, source, patch, image, and
  validated-profile pins.
- `tools/config_state.py`: typed configuration/lock parsing and atomic run
  state.
- `tools/fabric_probe.py`: normalized read-only fabric probe parsing.
- `tools/node_probe.py`: importable remote probes and local bounded SSH runner.
- `tools/artifact_manifest.py`: deterministic file manifest creation and
  verification.
- `tools/api_validation.py`: health, smoke, correctness, and needle checks.
- `tools/benchmark.py`: C1/C4 request execution and statistical summaries.
- `runtime/Containerfile`: reproducible runtime image build recipe.
- `runtime/patches/series.json`: ordered patch identities and content digests.
- `tests/`: unit, contract, fixture, and shell orchestration tests.
- `docs/operator-guide.md`: plan/apply operating procedure and recovery guide.
- `results/reference/README.md`: curation contract for sanitized evidence.
- `.github/workflows/ci.yml`: hardware-honest local and simulated checks.
- `scripts/qualify-clean-clone.sh`: isolated clean-clone qualification driver.
- `scripts/qualify-four-node.sh`: explicit live qualification gate.
- `docs/release-checklist.md`: final private-delivery evidence and release gate.

---

### Task 1: Config, reproduction lock, and atomic state

**Files:**
- Create: `glm53-spark`
- Create: `lib/common.sh`
- Create: `lib/config.sh`
- Create: `config/cluster.schema.json`
- Create: `config/cluster.example.json`
- Create: `config/reproduction.lock.json`
- Create: `tools/config_state.py`
- Create: `tests/test_config_state.py`
- Create: `tests/test_cli_contract.sh`
- Create: `tests/fixtures/cluster.valid.json`
- Create: `tests/fixtures/cluster.invalid-three-nodes.json`

**Responsibilities:**
- Enforce exactly four ordered nodes, exactly one source-node role, unique
  logical IDs, unique SSH aliases, absolute remote roots, and explicit ports.
- Reject unknown keys, embedded credentials, literal host inventory in tracked
  examples, and lock files whose validated profile differs from the approved
  values.
- Write versioned state beneath `.state/runs/<run-id>/` using same-directory
  temporary files, `fsync`, atomic replacement, and restrictive permissions.
- Parse global `--config`, `--lock`, `--state-root`, and `--apply` options
  without Bash features introduced after 3.2.
- The CLI initializes `APPLY=0` at process start, unsets any inherited `APPLY`,
  and only an explicit command-line `--apply` sets `APPLY=1`. Preexisting
  environment variables must never authorize mutation.

**Interfaces:**
- `load_cluster(path: pathlib.Path) -> ClusterConfig`
- `load_reproduction_lock(path: pathlib.Path) -> ReproductionLock`
- `write_run_state(state_root: pathlib.Path, state: RunState) -> pathlib.Path`
- `read_run_state(state_root: pathlib.Path, run_id: str) -> RunState`
- `new_run_id(now: datetime.datetime, entropy: bytes) -> str`
- `config_digest(cluster: ClusterConfig) -> str`
- `lock_digest(lock: ReproductionLock) -> str`
- `common_plan_or_apply APPLY PREFLIGHT ACTION...`: receive consent as an
  explicit internal parameter, print shell-escaped actions unless `APPLY` is
  1, and execute only when `PREFLIGHT` is also 1. The function must not read
  apply consent directly from the inherited environment.
- `config_export FIELD`: print one validated scalar for Bash consumers.

- [ ] **Step 1: Write failing config and state tests**

  Cover valid loading, three-node rejection, duplicate rank rejection,
  credential-key rejection, validated-profile lock rejection, deterministic
  digests, atomic replacement, malformed state rejection, and path traversal
  rejection. In `tests/test_cli_contract.sh`, launch the CLI with an inherited
  `APPLY=1` and prove a mutating subcommand remains plan-only; then pass an
  explicit command-line `--apply` to a fixed harmless mutation sentinel and
  prove execution occurs only after the preflight gate. The test seam must
  reject caller-supplied commands and arguments. Also assert initialization
  and inherited-variable removal happen before option parsing.

- [ ] **Step 2: Record RED evidence**

  Run:

  ```bash
  python3 -m unittest -v tests.test_config_state
  bash tests/test_cli_contract.sh
  ```

  Expected: FAIL because `tools.config_state` and `glm53-spark` do not exist.
  Save command, exit status, and failure excerpt in the task report.

- [ ] **Step 3: Implement schemas, lock, parser, and state writer**

  Use frozen dataclasses, `json`, `hashlib`, `tempfile`, `os.fsync`,
  `os.replace`, and explicit exceptions. Keep imports at module top level and
  expose the exact interfaces above.

- [ ] **Step 4: Implement the CLI dispatcher and safety primitive**

  The initial dispatcher validates config and lock before routing a subcommand.
  Unsupported commands exit 2. At the first executable statement after strict
  shell options, unset inherited apply state and initialize the internal flag
  to 0. Set it to 1 only in the parser branch that consumes the command-line
  `--apply`; export no consent flag, and pass the internal value explicitly to
  helpers that need it.

- [ ] **Step 5: Record GREEN evidence**

  ```bash
  python3 -m unittest -v tests.test_config_state
  bash tests/test_cli_contract.sh
  bash -n glm53-spark lib/common.sh lib/config.sh tests/test_cli_contract.sh
  git diff --check
  ```

  Expected: all tests pass, shell syntax checks exit 0, and the diff check is
  silent.

- [ ] **Step 6: Commit the independently reviewable task**

  ```bash
  git add glm53-spark lib config tools tests
  git commit -m "feat: add validated config and atomic state"
  ```

---

### Task 2: Read-only doctor and fabric discovery

**Files:**
- Create: `lib/doctor.sh`
- Create: `tools/fabric_probe.py`
- Create: `tools/node_probe.py`
- Create: `tests/test_doctor.sh`
- Create: `tests/test_fabric_probe.py`
- Create: `tests/test_node_probe.py`
- Create: `tests/fixtures/fabric/healthy.json`
- Create: `tests/fixtures/fabric/missing-link.json`
- Modify: `glm53-spark`

**Responsibilities:**
- Check local tools, strict SSH options, known-host coverage, remote logical
  identity, architecture, GPU visibility, storage, container runtime, required
  ports, source-node egress, and all six pairwise fabric paths.
- Remain read-only: no package installation, key enrollment, directory
  creation, firewall changes, sudo, or network changes.
- Return structured per-node and cross-node results with stable exit codes.

**Interfaces:**
- `doctor_run CONFIG_PATH LOCK_PATH -> exit 0|1|2`
- `doctor_ssh_options KNOWN_HOSTS_PATH -> newline-delimited argv`
- `run_ssh(argv, timeout_seconds) -> SSHExecution`
- `collect_node_probe(...) -> dict[str, object]`
- `probe_reachability(node_id, targets, command_runner) -> list[str]`
- `parse_probe(payload: str) -> FabricSnapshot`
- `evaluate_fabric(snapshot: FabricSnapshot) -> list[Finding]`
- `Finding.to_json() -> dict[str, object]`
- `glm53-spark doctor [--json]` consumes Task 1 validation and never accepts
  `--apply`.

- [ ] **Step 1: Write failing doctor and fabric tests**

  Assert exact strict SSH flags, stdin detachment, four-node identity mapping,
  six-link coverage, missing-link failure, stable JSON output, and rejection
  of every attempted mutation flag.

- [ ] **Step 2: Record RED evidence**

  ```bash
  bash tests/test_doctor.sh
  python3 -m unittest -v tests.test_fabric_probe
  ```

  Expected: FAIL because doctor and fabric probe implementations are absent.

- [ ] **Step 3: Implement read-only probes**

  Parse fixture and remote JSON through standard-library Python. Serialize the
  reviewed `tools/node_probe.py` source into explicit node and reachability
  remote modes without assuming installation. Build SSH commands as arrays in
  Bash, use `BatchMode=yes`, `StrictHostKeyChecking=yes`, exclusive dedicated
  user known-hosts, explicit Python-enforced connect/command timeouts, and
  `</dev/null`.

- [ ] **Step 4: Wire the doctor subcommand**

  Aggregate findings without hiding later read-only failures, redact command
  output, and exit 1 for failed requirements or 2 for invalid invocation.

- [ ] **Step 5: Record GREEN evidence**

  ```bash
  bash tests/test_doctor.sh
  python3 -m unittest -v tests.test_node_probe
  python3 -m unittest -v tests.test_fabric_probe
  bash -n glm53-spark lib/common.sh lib/config.sh lib/doctor.sh tests/test_doctor.sh
  git diff --check
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add glm53-spark lib/doctor.sh tools/fabric_probe.py tests
  git commit -m "feat: add read-only cluster doctor"
  ```

---

### Task 3: Reproducible image and model prepare

**Files:**
- Create: `lib/prepare.sh`
- Create: `lib/prepare_remote.sh`
- Create: `tools/artifact_manifest.py`
- Create: `tools/verify_hf_cache.py`
- Create: `runtime/Containerfile`
- Create: `runtime/patches/series.json`
- Create: `runtime/patches/sglang-glm53-gb10-tilelang.patch`
- Create: `manifests/glm53-target-aa28e1f5.json`
- Create: `manifests/glm53-draft-7d74cdd8.json`
- Create: `tests/test_prepare.sh`
- Create: `tests/test_artifact_manifest.py`
- Create: `tests/test_verify_hf_cache.py`
- Create: `tests/fixtures/manifest.valid.json`
- Modify: `glm53-spark`
- Modify: `lib/config.sh`
- Modify: `tools/config_state.py`
- Modify: `config/cluster.schema.json`
- Modify: `config/cluster.example.json`
- Modify: `config/reproduction.lock.json`
- Modify: `tests/test_config_state.py`
- Modify: `tests/test_cli_contract.sh`
- Modify: `tests/test_repository_contract.sh`

**Responsibilities:**
- Build locally on the configured source node from a digest-pinned base,
  source revisions, and digest-pinned ordered patches.
- Download both model repositories at pinned revisions without committing
  weights.
- Produce relative-path, size, and SHA-256 manifests; verify before and after
  resumable distribution; promote only complete verified artifacts.
- Preserve partial transfers and failure evidence without automatic cleanup.
- Keep authoritative Hub manifests tracked at lock-pinned digests, apply the
  ordered GB10 patch series byte-for-byte, and verify full snapshot/blob
  identity before reuse or promotion.
- Extend ignored machine-local cluster configuration with per-node absolute
  cache roots and fabric IPv4 addresses plus a source-side dedicated fabric known-hosts
  path. Cross-node SSH must use that file exclusively with strict checking and
  no trust-on-first-use mode.
- Export an image tar once on the source, hash it, transfer it resumably, verify
  it before loading, record all legitimate image IDs, and require identical
  RootFS layers on all nodes.

**Interfaces:**
- `build_manifest(root: pathlib.Path) -> ArtifactManifest`
- `verify_manifest(root: pathlib.Path, manifest: ArtifactManifest) -> list[Finding]`
- `verify_hf_cache(cache_root: pathlib.Path, manifest_path: pathlib.Path) -> list[CacheFinding]`
- `prepare_plan CONFIG LOCK RUN_ID -> newline-delimited action records`
- `prepare_apply CONFIG LOCK RUN_ID`: require matching fresh doctor evidence
  and execute the exact stored plan.
- `glm53-spark prepare [--apply]` defaults to a non-mutating plan.
- Apply requires `--acknowledge-draft-license CC-BY-NC-ND-4.0` and the exact printed plan digest.
  Any stale configuration, lock, plan, local artifact, or
  remote identity fails closed before mutation.

- [ ] **Step 1: Write failing manifest and prepare tests**

  Cover deterministic sort order, symlink and non-regular-file rejection,
  digest mismatch, interrupted-transfer preservation, exact source-node role,
  plan-by-default behavior, stale-plan rejection, and no cleanup commands.

- [ ] **Step 2: Record RED evidence**

  ```bash
  python3 -m unittest -v tests.test_artifact_manifest
  bash tests/test_prepare.sh
  ```

  Expected: FAIL because manifest and prepare implementations are absent.

- [ ] **Step 3: Implement deterministic manifest handling**

  Stream SHA-256 calculations, reject paths outside the artifact root, emit
  canonical JSON, and return explicit findings rather than assertions.

- [ ] **Step 4: Implement source-node reproduction and distribution**

  Plan exact build, download, verify, transfer, remote verify, and atomic
  promotion actions. Apply only the recorded action set after digest and
  identity gates; use resumable transfer options and never delete partials.

- [ ] **Step 5: Record GREEN evidence**

  ```bash
  python3 -m unittest -v tests.test_artifact_manifest
  bash tests/test_prepare.sh
  bash -n glm53-spark lib/common.sh lib/config.sh lib/prepare.sh tests/test_prepare.sh
  git diff --check
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add glm53-spark lib/prepare.sh tools/artifact_manifest.py runtime config/reproduction.lock.json tests
  git commit -m "feat: add reproducible artifact preparation"
  ```

---

### Task 4: TP4 lifecycle and rollback

**Files:**
- Create: `lib/lifecycle.sh`
- Create: `tests/test_lifecycle.sh`
- Create: `tests/fixtures/lifecycle/prelaunch-services.json`
- Create: `tests/fixtures/lifecycle/rank-failure.json`
- Modify: `glm53-spark`
- Modify: `tools/config_state.py`

**Responsibilities:**
- Record pre-launch service state, exact rank ownership, arguments, mounts,
  ports, artifact identities, and rollback actions.
- Implement parallel two-phase TP4 startup: validate/stage all four ranks,
  release all four concurrently, then wait for collective and direct API
  health.
- Implement read-only status/logs plus owned stop and rollback; never touch an
  unowned container or delete an artifact.

**Interfaces:**
- `lifecycle_plan MODE RUN_ID -> newline-delimited action records`
- `lifecycle_launch RUN_ID`, `lifecycle_stop RUN_ID`, and
  `lifecycle_rollback RUN_ID` execute only with `--apply` and exact ownership.
- `lifecycle_status RUN_ID -> exit 0|1`
- `lifecycle_logs RUN_ID RANK -> exit 0|1`
- `append_run_event(state_root: pathlib.Path, run_id: str, event: RunEvent) -> None`
- `glm53-spark launch|status|logs|stop|rollback` dispatches these interfaces.

- [ ] **Step 1: Write failing lifecycle tests**

  Use fake SSH and runtime executables to prove four-rank phase-one completion
  precedes launch, all launches are concurrent, early-rank failure triggers
  only run-owned stop actions, rollback restores recorded service state, and
  every mutation remains plan-only without `--apply`.

- [ ] **Step 2: Record RED evidence**

  ```bash
  bash tests/test_lifecycle.sh
  python3 -m unittest -v tests.test_config_state
  ```

  Expected: FAIL on missing lifecycle functions and run event support.

- [ ] **Step 3: Implement lifecycle planning and ownership gates**

  Assign ranks 0 through 3 from validated order, use run-specific container
  labels, store shell-escaped action arrays, and reject stale config, lock,
  image, model, path, port, or owner identity.

- [ ] **Step 4: Implement parallel startup and rollback**

  Start one background SSH process per rank with stdin detached, collect every
  PID and exit status, enforce bounded health waits, and preserve per-rank
  logs. Roll back only state recorded before this run.

- [ ] **Step 5: Record GREEN evidence**

  ```bash
  bash tests/test_lifecycle.sh
  python3 -m unittest -v tests.test_config_state
  bash -n glm53-spark lib/common.sh lib/config.sh lib/lifecycle.sh tests/test_lifecycle.sh
  git diff --check
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add glm53-spark lib/lifecycle.sh tools/config_state.py tests
  git commit -m "feat: add fail-closed TP4 lifecycle"
  ```

---

### Task 5: Validation and benchmark

**Files:**
- Create: `lib/validate.sh`
- Create: `tools/api_validation.py`
- Create: `tools/benchmark.py`
- Create: `tests/test_api_validation.py`
- Create: `tests/test_benchmark.py`
- Create: `tests/test_validate.sh`
- Create: `tests/fixtures/api/health.ok.json`
- Create: `tests/fixtures/api/chat.arithmetic.ok.json`
- Create: `tests/fixtures/api/chat.tool-call.ok.json`
- Create: `tests/fixtures/api/malformed.txt`
- Create: `tests/fixtures/benchmark/c1-samples.json`
- Create: `tests/fixtures/benchmark/c4-samples.json`
- Modify: `glm53-spark`

**Responsibilities:**
- Validate health, model identity, smoke behavior, arithmetic, code, Turkish,
  and structured tool calling with explicit HTTP timeouts and error classes.
- Generate a deterministic 120K needle suite at 10%, 50%, and 90% insertion
  depths and verify exact retrieval.
- Run C1 and C4 benchmarks, preserving request configuration, per-request
  measurements, aggregate throughput, latency percentiles, and failures.

**Interfaces:**
- `OpenAIClient(base_url: str, timeout_seconds: float).chat(request: dict[str, object]) -> dict[str, object]`
- `build_needle_case(total_tokens: int, depth_percent: int, seed: int) -> NeedleCase`
- `evaluate_case(case: ValidationCase, response: dict[str, object]) -> CaseResult`
- `run_benchmark(client: OpenAIClient, requests: list[BenchmarkRequest], concurrency: int) -> BenchmarkResult`
- `glm53-spark validate [--suite smoke|correctness|needle|benchmark|all]`
  writes generated output beneath `results/validation/<run-id>/`.

- [ ] **Step 1: Write failing validation tests**

  Cover malformed JSON, HTTP failure, timeout, wrong model, wrong answer,
  deterministic needle placement, all three depths, C1/C4 scheduling,
  percentile calculation, partial failure, and sanitized output.

- [ ] **Step 2: Record RED evidence**

  ```bash
  python3 -m unittest -v tests.test_api_validation tests.test_benchmark
  bash tests/test_validate.sh
  ```

  Expected: FAIL because validation and benchmark implementations are absent.

- [ ] **Step 3: Implement API and correctness validation**

  Use `urllib.request`, `concurrent.futures`, `json`, `statistics`, and
  monotonic clocks. Keep top-level imports, explicit input validation, bounded
  response reads, and distinct infrastructure/correctness outcomes.

- [ ] **Step 4: Implement benchmark orchestration**

  Enforce concurrency values 1 and 4 only, tie output to an active healthy
  run, record the validated profile, and never include prompts containing
  credentials or local inventory in curated summaries.

- [ ] **Step 5: Record GREEN evidence**

  ```bash
  python3 -m unittest -v tests.test_api_validation tests.test_benchmark
  bash tests/test_validate.sh
  bash -n glm53-spark lib/common.sh lib/config.sh lib/validate.sh tests/test_validate.sh
  git diff --check
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add glm53-spark lib/validate.sh tools/api_validation.py tools/benchmark.py tests
  git commit -m "feat: add correctness and throughput validation"
  ```

---

### Task 6: Docs, reference artifacts, and CI

**Files:**
- Create: `docs/operator-guide.md`
- Create: `results/reference/README.md`
- Create: `.github/workflows/ci.yml`
- Create: `tests/test_documentation_contract.sh`
- Create: `tests/test_reproduction_lock.py`
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `CONTRIBUTING.md`

**Responsibilities:**
- Document configuration, strict SSH setup, doctor, prepare, launch, validate,
  status/logs, stop, rollback, failure recovery, and artifact curation.
- Explain that CI validates software behavior through local fixtures and
  simulation but cannot qualify DGX hardware.
- Accept only sanitized, reviewed, compact reference summaries with source
  commit, lock digest, profile, test method, and explicit hardware-validation
  provenance.

**Interfaces:**
- `tests/test_documentation_contract.sh` checks links, commands, license
  boundaries, four-node scope, plan/apply language, and hardware-honest claims.
- `tests/test_reproduction_lock.py` checks every pinned revision/digest field
  and the exact validated profile.
- CI invokes `bash tests/test_repository_contract.sh`, all shell contract
  tests, `bash -n` over tracked shell files, and
  `python3 -m unittest discover -v`.

- [ ] **Step 1: Write failing documentation and lock tests**

  Add assertions for every operator command, recovery path, curation field,
  exact profile value, and CI entry point.

- [ ] **Step 2: Record RED evidence**

  ```bash
  bash tests/test_documentation_contract.sh
  python3 -m unittest -v tests.test_reproduction_lock
  ```

  Expected: FAIL because the operator guide, reference policy, and CI workflow
  do not exist.

- [ ] **Step 3: Write operator and curation documentation**

  Include concrete command examples using synthetic aliases and non-routable
  documentation addresses. State every safety gate, expected output class,
  recovery decision, and prohibition on automatic cleanup.

- [ ] **Step 4: Add hardware-honest CI**

  Pin action versions to commit SHAs, use no repository secrets, reject large
  or sensitive artifacts, and label simulated lifecycle checks explicitly.

- [ ] **Step 5: Record GREEN evidence**

  ```bash
  bash tests/test_documentation_contract.sh
  python3 -m unittest -v tests.test_reproduction_lock
  bash tests/test_repository_contract.sh
  python3 -m unittest discover -v
  git diff --check
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add README.md SECURITY.md CONTRIBUTING.md docs results/reference .github tests
  git commit -m "docs: add operations guide and honest CI"
  ```

---

### Task 7: Clean-clone and live four-node qualification

**Files:**
- Create: `scripts/qualify-clean-clone.sh`
- Create: `scripts/qualify-four-node.sh`
- Create: `tests/test_qualification_scripts.sh`
- Create: `docs/qualification.md`

**Responsibilities:**
- Prove a private clean clone can run all local tests and produce identical
  plan output from supplied machine-local config and the tracked lock.
- Gate live qualification behind explicit operator confirmation, a clean
  commit, exact config/lock digests, four healthy nodes, verified artifacts,
  and `--apply`.
- Exercise doctor, prepare verification, launch, smoke, correctness, 120K
  needle at 10/50/90%, C1/C4, status/logs, stop, and rollback while preserving
  sanitized evidence.

**Interfaces:**
- `scripts/qualify-clean-clone.sh REPOSITORY_URL COMMIT DESTINATION`
- `scripts/qualify-four-node.sh --config PATH --lock PATH --state-root PATH`
  prints a qualification plan by default.
- `scripts/qualify-four-node.sh ... --apply --confirm-four-node-qualification`
  performs the exact recorded plan.
- Both scripts emit a final machine-readable summary path and nonzero status
  for any skipped or failed required gate.

- [ ] **Step 1: Write failing qualification-script tests**

  Fake Git, SSH, runtime, and API commands to assert clean-commit pinning,
  private URL handling without credential logging, default no-op behavior,
  confirmation enforcement, ordered suites, failure preservation, and
  sanitized summary output.

- [ ] **Step 2: Record RED evidence**

  ```bash
  bash tests/test_qualification_scripts.sh
  ```

  Expected: FAIL because qualification scripts do not exist.

- [ ] **Step 3: Implement clean-clone qualification**

  Clone to an operator-supplied empty directory, checkout the exact commit,
  run the complete local verification set, compare lock and generated plan
  digests, and leave the clone intact for inspection.

- [ ] **Step 4: Implement live four-node qualification**

  Reuse only public CLI interfaces, require explicit apply confirmation,
  capture phase outcomes atomically, stop on the first unsafe transition, and
  preserve all non-secret failure evidence without cleanup.

- [ ] **Step 5: Execute qualification gates**

  ```bash
  bash tests/test_qualification_scripts.sh
  bash -n scripts/qualify-clean-clone.sh scripts/qualify-four-node.sh
  bash scripts/qualify-clean-clone.sh "$PRIVATE_REPOSITORY_URL" "$(git rev-parse HEAD)" "$QUALIFICATION_CLONE"
  bash scripts/qualify-four-node.sh --config "$CLUSTER_CONFIG" --lock config/reproduction.lock.json --state-root .state
  ```

  Expected before live apply: local tests pass; clean-clone plan digest
  matches; live command prints a complete no-mutation plan. An authorized
  operator then reruns the printed command with
  `--apply --confirm-four-node-qualification` and records every required
  result.

- [ ] **Step 6: Record GREEN evidence**

  ```bash
  bash tests/test_qualification_scripts.sh
  bash tests/test_repository_contract.sh
  python3 -m unittest discover -v
  git diff --check
  ```

- [ ] **Step 7: Commit sanitized evidence only**

  ```bash
  git add scripts tests/test_qualification_scripts.sh docs/qualification.md results/reference
  git commit -m "test: add clean-clone and four-node qualification"
  ```

---

### Task 8: Final review and private GitHub delivery

**Files:**
- Create: `docs/release-checklist.md`
- Create: `tests/test_release_contract.sh`
- Modify: `README.md`
- Modify: `results/reference/README.md`

**Responsibilities:**
- Audit every tracked file for credentials, inventory, large artifacts,
  license accuracy, unsupported claims, and destructive behavior.
- Verify clean-clone and live four-node evidence points to the exact release
  commit and immutable reproduction-lock digest.
- Deliver only to a private GitHub repository, verify remote visibility, and
  preserve an auditable final release checklist.

**Interfaces:**
- `tests/test_release_contract.sh` rejects missing qualification evidence,
  forbidden strings, oversized files, and unpinned CI actions.
- `tests/test_release_contract.sh --delivery` additionally rejects dirty
  state, untracked release artifacts, and non-private remote metadata.
- `docs/release-checklist.md` records command, timestamp, exit status, commit,
  lock digest, evidence paths, reviewer, and private-visibility verification
  for every gate.

- [ ] **Step 1: Write the failing release contract**

  Assert the exact evidence fields and all release prohibitions before writing
  the checklist or changing delivery metadata.

- [ ] **Step 2: Record RED evidence**

  ```bash
  bash tests/test_release_contract.sh
  ```

  Expected: FAIL because the release checklist and final evidence links are
  absent.

- [ ] **Step 3: Perform the focused final review**

  Review `git ls-files` one file at a time, inspect repository history,
  validate Apache-2.0 and third-party notices, scan for secrets and inventory,
  verify file sizes, and confirm no command authorizes cleanup, firewall,
  sudo, or network mutation.

- [ ] **Step 4: Write the release checklist and final links**

  Record the exact review commands and outcomes, exact clean-clone and live
  qualification evidence paths, release commit candidate, reproduction-lock
  digest, and required private-visibility post-delivery gate. Update the
  landing page and reference policy to link this evidence without claiming the
  release has been delivered.

- [ ] **Step 5: Run the complete pre-delivery verification**

  ```bash
  bash tests/test_repository_contract.sh
  bash tests/test_documentation_contract.sh
  bash tests/test_release_contract.sh
  python3 -m unittest discover -v
  bash -n glm53-spark lib/*.sh scripts/*.sh tests/*.sh
  git diff --check
  ```

  Expected: all tests and syntax checks pass and the diff check is silent.

- [ ] **Step 6: Commit the release gate**

  ```bash
  git add README.md docs/release-checklist.md results/reference/README.md tests/test_release_contract.sh
  git commit -m "chore: finalize private initial release"
  ```

- [ ] **Step 7: Create or verify the private GitHub destination**

  ```bash
  gh repo view --json nameWithOwner,visibility
  ```

  Expected: `visibility` is `PRIVATE`. If no remote repository exists, create
  it explicitly with `gh repo create --private --source=. --remote=origin`
  and verify `PRIVATE` before any push.

- [ ] **Step 8: Run the delivery gate**

  ```bash
  bash tests/test_release_contract.sh --delivery
  git status --short
  ```

  Expected: the delivery contract passes and status output is empty.

- [ ] **Step 9: Push without rewriting history**

  ```bash
  git push -u origin feat/initial-release
  ```

  Verify the remote branch commit equals local `HEAD`, repository visibility
  remains `PRIVATE`, and no model weights or container images appear in the
  remote tree.

## Plan self-review

- Every approved design requirement maps to at least one task and an explicit
  verification gate.
- File responsibilities are separated by host orchestration, validated data,
  artifact handling, lifecycle, validation, documentation, qualification, and
  release.
- Cross-task interfaces use stable names and carry config, lock, run, and
  ownership identity explicitly.
- Each task starts with an expected RED result, reaches GREEN, runs syntax and
  diff checks, and ends with an independently reviewable commit.
- No step authorizes destructive cleanup or firewall, sudo, or network
  mutation.
