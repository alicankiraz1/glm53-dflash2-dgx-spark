# Curated reference artifacts

This directory is the tracked boundary for compact, reviewed evidence that is
safe to share with the repository. It is intentionally separate from
`results/validation/`, which contains run-scoped output and is ignored by
default.

## What a reference artifact may contain

A reference summary may include:

- the source commit or historical report basename;
- the reproduction-lock digest and locked profile;
- the provenance class: `local-fixture`, `source-node`, or
  `historical-source-deployment`;
- suite outcomes and bounded measurements;
- artifact basenames and their SHA-256 values; and
- a clear statement of what the evidence does and does not establish.

Keep summaries compact, deterministic, and readable without access to the
operator's machine. JSON is preferred for machine-consumable metadata. If a
large artifact is needed for independent review, publish it through an
authorized artifact channel and record only its basename, digest, and
provenance here.

## What must stay out

Do not commit model weights, container archives, raw logs, prompts containing
secrets, credentials, private keys, API tokens, deployment inventory, host
names, machine IDs, absolute local paths, or unreviewed screenshots. Do not
copy a raw validation directory into this location.

Historical source-deployment evidence must retain that label. It is not fresh
qualification of this package, hardware acceptance, or a speedup claim. A
benchmark number without a controlled comparison must not be described as an
improvement.

## Review checklist

Before tracking a new reference summary, verify:

1. every path is a basename or repository-relative path;
2. every digest is computed from the artifact that the summary names;
3. the source revision, lock identity, profile, and provenance are explicit;
4. the summary contains no inventory or account-specific value; and
5. the repository contract and documentation checks pass.

The historical example in this directory is deliberately limited to the
locked profile's long-context and throughput summary. It does not assert that
the current checkout has been deployed or qualified on hardware.
