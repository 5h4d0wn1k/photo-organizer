# Engineering Operating System Scorecard

Use this scorecard to track whether the repository can sustain the full Private
Gallery goal: cross-platform privacy-first shared storage plus smart organization
for media, documents, and work files.

## Current Maturity Snapshot

| Area | Status | Evidence |
| --- | --- | --- |
| Product vision | Mature | Product vision, PRFAQ, critical journeys. |
| Business model | Mature draft | Monetization review, unit economics, year-one roadmap. |
| Architecture decision | Mature draft | Local-first encrypted device-group ADR. |
| Release operations | In progress | Release checklist, production runbook, rollback checklist. |
| Reliability | In progress | SLO guide, PRR template, postmortem template. |
| Ownership | In progress | Service ownership runbook. |
| Platform completion | In progress | Platform release and entitlements plan. |
| Implementation completeness | In progress | Current MVP supports Linux/Android baseline; full target remains incomplete. |

## Monthly Review Questions

- Can a new contributor explain the north star and non-goals?
- Can a user complete first library, import, pair, search, transfer, availability,
  and backup verification on the scoped platforms?
- Are platform release artifacts signed, packaged, tested, and rollbackable?
- Do entitlement checks preserve local access and avoid content-derived data?
- Are support bundles privacy-preserving?
- Are business/workspace features tested for authorization and audit?
- Did any release weaken route boundaries, encryption, backup, or revocation?

## Red/Yellow/Green Criteria

Green:

- Current release scope has evidence for product, security, reliability,
  platform, ownership, and rollback.
- No known content-hosting or telemetry drift.
- Critical user journeys pass in release smoke.

Yellow:

- Docs exist but evidence is partial.
- Some platforms are beta-only or manual-runbook-only.
- Entitlement or relay behavior is not yet automated but is bounded.

Red:

- No owner for a release-scoped surface.
- Remote route boundaries, encryption, backup, or revocation are unverified.
- Paid tier blocks safe local access or uses content-derived billing data.
- Store/privacy disclosures do not match actual behavior.

## Next Scorecard Improvements

- Add repo-local Codex config and rules.
- Add automated checks that recognize app and Rust test surfaces.
- Add platform-specific release evidence templates.
- Add business/workspace authorization test gates when workspace features ship.
