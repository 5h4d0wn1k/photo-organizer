# Security Policy

## Supported Scope

This repository is targeting private beta quality for Linux desktop plus Android. The supported sync posture is local-first storage with encrypted managed originals and mobile access through Tailscale/HTTPS where available. Plain LAN HTTP is development mode only and must be enabled deliberately.

## Secret Handling

- Do not commit `.env`, `.env.*`, `env`, private keys, service-account files, bearer tokens, Supabase credentials, signing keys, or generated local runtime databases.
- If a secret is written into this workspace, remove it from git and rotate it at the provider before sharing the branch.
- The root `env` file in this workspace was treated as exposed secret material. Every credential that appeared in it must be rotated outside this repository.

## Reporting

For private beta issues, report security problems directly to the repository owner with:

- Affected commit or build.
- Reproduction steps.
- Whether media, vault keys, bearer tokens, device pairing tokens, OCR text, or metadata could be exposed or modified.

Private vulnerability reports can also be filed via the GitHub Private Vulnerability Reporting form: <https://github.com/5h4d0wn1k/photo-organizer/security/advisories/new>

Do not attach private photos, videos, vault keys, bearer tokens, pairing payloads, `.env` files, or production database copies to issue reports.

## Release Gate

Before any beta build:

- Secret scan must pass.
- Rust format, clippy, tests, dependency audit, and SBOM generation must pass.
- Flutter analyze and tests must pass.
- Mobile sessions must support expiry and revocation.
- Remote clients must be limited to `/health` and authenticated `/mobile/*`.
- Backup/restore verification must include encrypted vault chunks.

## Disclosure Timeline

We follow a coordinated disclosure process. Reported issues are acknowledged and
handled within the following windows:

| Step                     | Target window          |
| ------------------------ | ---------------------- |
| Initial acknowledgement  | Within 72 hours        |
| Triage and status update | Within 5 business days |
| Coordinated fix release  | Handled with reporter  |
| Public disclosure        | After 90 days, unless agreed otherwise |

Public disclosure happens only after a fix is available or the 90-day window
elapses, whichever comes first, and only with the reporter's agreement where
reasonable.
