# Release readiness corrections

## Objective and current state

Prepare the local deployment package for review and sharing, preserving the
existing validation and benchmark implementation. The committed launcher has
two incompatible SGLang option names, the local lifecycle test expects an old
validation stub, and operator documentation and CI are incomplete.

## Scope and non-goals

Correct launch arguments, source-image recovery and immutable rank ownership;
separate validation request and suite budgets; add focused regression checks,
an offline check command and CI; refresh README, operator guidance and reference
evidence. No live cluster operation, model/image download, commit, push or change
to repository visibility belongs to this task.

## Assumptions

The pinned source, model revisions and C4/128K profile remain the intended
reproduction inputs. Historical deployment results are evidence of that earlier
deployment only. Existing uncommitted work is retained and integrated locally.

## Acceptance and validation

1. Generated launch arguments match the pinned SGLang CLI: isolated upstream
   parser contract plus regression tests rejecting the two invalid names.
2. Prepare recovers a missing source image from its verified export and rejects
   mismatched images: fake-runtime RED/GREEN tests.
3. Lifecycle mutations reject replaced rank containers: immutable-ID regression,
   partial-launch abort and rollback tests.
4. Validation has distinct request/suite limits: local fake-client/watchdog tests.
5. README commands, links, license boundaries and qualification statements agree
   with code: documentation contract and independent review.
6. Full offline tests, Bash syntax, ShellCheck and whitespace checks pass in the
   working tree and a separate candidate snapshot including intended new files.
7. CI runs offline software checks and a separately named pinned-source check;
   it makes no hardware-validation claim.

## Phase graph and ownership

Inspect/baseline -> parallel implementation -> integrated checks -> independent
review -> revisions if needed -> candidate snapshot verification -> report.

- Primary agent: upstream contract, reproduction/documentation tests, check
  command, CI, integration, final evidence.
- Terra High lifecycle worker: lifecycle library, state utility and their tests.
- Terra Medium prepare worker: remote prepare library and its contract test.
- Terra Medium validation worker: validation shell library and tests.
- Luna High documentation worker: README, operator guide, notices, contributing
  guide and curated reference material.
- Luna High progress controller: read-only acceptance and scope checks.
- Sol High final reviewer: independent read-only review of the integrated diff.

## Stop condition

All applicable local acceptance criteria pass and the README is usable and
accurate. Any remaining live qualification or remote delivery is reported
explicitly without presenting offline results as a deployed release.

## Evidence

Implemented the CLI corrections, source-image recovery, shared run-ID
validation, immutable rank/service mutation targets, separate validation
budgets, documentation, historical reference summary, offline checker and CI.

Focused regressions cover rejected upstream option names, image-label mismatch,
missing source-image recovery, replacement/rename drift, partial-launch
receipts, and cumulative request timeouts. The pinned source contract checks
all four generated rank commands and verifies patch application without
building the image or executing upstream code.

Final working-tree and independent snapshot checks, preservation evidence and
review outcomes belong in the accompanying local release report. That report
must identify the tested candidate and distinguish software checks from live
hardware qualification and a committed or published release.
