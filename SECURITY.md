# Security Policy

## Supported versions

The project is in initial development. Only the current default branch is
eligible for security fixes.

## Reporting a vulnerability

Do not open a public issue containing vulnerability details, credentials,
cluster inventory, logs with sensitive data, or reproduction artifacts that
could expose a deployment. Use the private repository's security advisory
workflow or contact a repository maintainer through an established private
channel.

Include the affected commit, impact, minimal reproduction steps, and any
suggested mitigation. Remove hostnames, addresses, usernames, tokens, keys,
and model access credentials from every attachment.

Maintainers should acknowledge a complete report within seven calendar days,
coordinate remediation privately, and publish only sanitized information.

## Operational scope

The planned tooling uses strict key-based SSH with pinned `known_hosts`
entries. Mutating operations will produce a plan by default and require an
explicit `--apply`. The project will not automate firewall, sudo, or network
configuration and will not perform automatic cache cleanup.
