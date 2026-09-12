# Contributing

This project accepts focused changes that preserve reproducibility, explicit
safety gates, and the fixed four-node TP4 scope.

## Development requirements

- Keep host orchestration compatible with macOS Bash 3.2.
- Use Python 3.11 or newer and only the Python standard library for repository
  tools.
- Write repository prose and code comments in English.
- Make every runtime mutation plan-only by default and require `--apply`.
- Use strict key-based SSH and pinned `known_hosts`; never weaken host checks.
- Do not add model weights, container image archives, generated validation
  output, credentials, local runtime state, or deployment inventory.
- Do not add automatic cleanup or firewall, sudo, or network mutations.

Documentation changes must keep command examples aligned with the current CLI,
preserve the distinction between plan and apply, and label source-deployment
or historical evidence separately from local software checks. Do not place
absolute paths, host inventory, machine identities, credentials, model weights,
or container archives in documentation or curated reference artifacts.

## Test-driven workflow

1. Write a focused test for the intended behavior.
2. Run it and record the expected failure before implementation.
3. Implement the smallest change that satisfies the test.
4. Run the focused test, relevant regression tests, syntax checks, and
   `git diff --check`.
5. Review the diff for secrets, lab-specific values, generated artifacts, and
   accidental scope growth.

Run the complete offline check for every change. `scripts/check.sh` runs the
repository contract, shell syntax checks, ShellCheck, Python tests, and
documentation/reproduction checks; ShellCheck 0.11.0 is the pinned CI version
for this command.

```bash
bash scripts/check.sh
```

When upstream source text needs refreshing, the optional verifier may be run:

```bash
python3 tools/verify_upstream_contract.py
```

It fetches only the pinned upstream text contract and patch metadata. It does
not download model images, run CUDA, start a service, or qualify hardware.

Hardware-dependent behavior must be covered by deterministic local seams and
clearly separated from an explicitly authorized live qualification. CI must
not claim to validate DGX hardware.

## Changes and reviews

Keep commits independently reviewable and use concise Conventional Commit
messages. Pull requests should state the RED and GREEN evidence, operational
risk, rollback behavior, and whether any live four-node qualification was
performed.

By contributing, you agree that your contribution is licensed under the
Apache License 2.0.
