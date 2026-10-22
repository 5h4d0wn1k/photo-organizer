# ADR: Upgrade the sync transport from Iroh 0.98 to Iroh 1.x

## Status

Proposed. The dependency and transfer-contract evidence supports this upgrade,
but the project acceptance gate remains open until a mixed-version verified
sync transfer is exercised by both historical and current application code.

## Context

The sync transport used Iroh 0.98.2. Issue #122 identified three remaining
transitive audit warnings in that release's graph: `atomic-polyfill` was
unmaintained, `paste` was unmaintained, and `lru` had a judged unsoundness
advisory. Separately, `.cargo/audit.toml` ignored two Hickory DNSSEC advisories
because of Iroh's pinned resolver graph. Iroh 1.x replaces parts of that graph
and changes public endpoint, relay, and DNS APIs. Existing paired devices must
retain their identity and continue to exchange data across an upgrade.

The app protocol currently uses ALPN
`private-gallery/vault-sync/1`, a protocol version field, JSON-framed Push and
Pull requests, and authenticated encrypted chunk envelopes. An ALPN match alone
does not prove that old and new application implementations can complete a
verified transfer.

## Requirements

- Remove the vulnerable/unmaintained Iroh 0.98 dependency subtree without
  weakening the product's encryption, pairing, or local-first guarantees.
- Preserve enrolled device identity and the existing sync ALPN and protocol
  unless a separately reviewed migration is required.
- Prove compatibility with an actual mixed-version push/pull and verified
  encrypted-chunk transfer before marking this migration complete.
- Keep test infrastructure hermetic and avoid relying on public relay services
  or hosted user data.
- Disclose differences in direct connectivity and relay support to users and
  operators.

## Options considered

### Stay on Iroh 0.98.2

This avoids the major API migration and reduces immediate compatibility risk.
It leaves the vulnerable dependency path in the graph and requires maintaining
the existing audit verdicts.

### Upgrade to Iroh 1.x

This removes the Hickory packages and their ignored advisories, upgrades `lru`
to a patched release, and removes `atomic-polyfill`. It still reports
`paste` as unmaintained, which remains visible and is not hidden by the audit
configuration. The lockfile also advances `yoke-derive` from yanked 0.8.3 to
0.8.4. It moves to a new major API and requires auditing
endpoint construction, discovery, relay behavior, and mixed-version
compatibility.

### Maintain a fork or patch of Iroh 0.98

This could remove individual advisories while minimizing API churn, but transfers
security maintenance and dependency backports to this project and preserves a
deprecated major line.

## Decision

Proceed with the Iroh 1.x API, retaining the current app ALPN and protocol
version. The manifest requires Iroh 1.3.0 or newer in the compatible 1.x line;
the current lockfile resolves Iroh 1.4.1. The dependency graph is updated and
the former Hickory ignores are removed.
Repository tests cover the Iroh 1.x transport and service behavior.

An isolated, direct-loopback probe was run with separate 0.98.2 and 1.3.0
programs using the app ALPN and the same persisted test key. Same-version
controls passed, and both mixed-version directions established the same peer
identity and exchanged bidirectional stream data. This establishes direct
transport and ALPN interoperability only. It does **not** exercise the app's
Push/Pull request format, encrypted chunk envelope, verified transfer, or
replica persistence. That remaining proof is a release gate, not an assumed
consequence of ALPN compatibility.

A repository test now drives the current production Push/Pull runtime against
a hermetic peer linked to Iroh 0.98.2. It verifies the v1 framed transfer
contract, encrypted bytes, receiver persistence, and completed transfer state
in both directions. The old-side application behavior in this test is an
independent fixture implementation, not the historical Photo Organizer
0.98.2 application. Therefore this is useful contract-regression evidence but
does not close the old-app/new-app acceptance gate or issue #122.

## Tradeoffs

- The new dependency tree contains no Hickory packages and no known
  vulnerabilities (`cargo audit --json`: zero vulnerabilities). It removes the
  old `atomic-polyfill` and `lru` warnings and removes the Hickory suppressions.
  `paste` remains an unmaintained compile-time macro dependency through
  `netwatch -> netlink-packet-route -> netlink-packet-core`; that warning is
  visible and not suppressed. The yanked `yoke-derive` 0.8.3 lock entry is
  updated to 0.8.4.
- Iroh 1.x is the supported direction, but this is a major API change with
  additional maintenance and test burden.
- Direct mixed-version transport works in the probe. Relay interoperability
  has not been tested. Iroh's public relay support for 0.9x clients ended on
  2026-09-30; users needing public-relay sync should upgrade all paired devices
  to Iroh 1.x. This does not establish that direct old-peer connectivity is
  unavailable.
- Keeping the existing ALPN avoids an unnecessary identity or protocol switch,
  but requires tests to guard the wire contract explicitly.

## Rollout and follow-up

1. Run dependency audit, Rust tests, and the platform CI matrix on the upgrade.
2. Verify an existing Iroh key written by the 0.98.2 application's
   `identity/iroh_endpoint.key` path loads unchanged through the app's
   `load_or_create_secret_key` path, produces the enrolled device's existing
   endpoint identity, and remains paired through a real endpoint descriptor.
   Use only test keys and isolated runtime roots.
3. Keep the current fixture test as wire-contract regression coverage. Add a
   hermetic test that runs the historical Photo Organizer implementation linked
   to Iroh 0.98.2 against the current production implementation linked to Iroh
   1.x. Verify Push and Pull, encrypted chunk hashes, persisted replica health,
   and completed transfer state in both directions.
4. Keep issue #122 open until that old-app/new-app test passes. Do not describe
   the migration as fully accepted or close the issue based on a cloned peer.
5. Explain that relay behavior may differ from direct connectivity during
   release notes and device-upgrade guidance.

## Reversibility

The package/API change is reversible while the wire protocol remains
unchanged, but operational rollback is degraded: Iroh 0.98 peers cannot rely on
public-relay service after the published 2026-09-30 cutoff. Rolling the app
back may still permit direct connections on suitable networks, but must not be
presented as restoring relay-backed sync. A rollback plan must direct affected
users to restore the 1.x build or upgrade all paired devices to 1.x before
depending on public-relay sync. Rollback also reintroduces the old dependency
graph and requires a renewed audit decision. A future wire-format change would
be a separate, potentially one-way compatibility decision and needs its own
versioning and migration plan.

## Re-evaluation triggers

- The verified mixed-version application transfer test fails in either
  direction.
- A required direct-network or relay behavior is unavailable on supported
  platforms.
- Iroh introduces a security, maintenance, or licensing concern that outweighs
  the current dependency and compatibility benefits.
- The app wire protocol changes in a way that requires paired-device
  migration.
