# Postmortem Template

Use this for privacy, data-integrity, startup, import, sync, entitlement,
platform release, backup/restore, or business/workspace incidents.

## Summary

- Incident title:
- Date/time:
- Release or commit:
- Platforms affected:
- Severity:
- Incident owner:
- Current status:

## User Impact

- What user journey failed?
- Which users or devices were affected?
- Was any file, media, metadata, OCR text, embedding, face data, key, token, or
  private workspace content exposed?
- Was any data lost, corrupted, duplicated, or made unavailable?
- Did paid entitlements block safe local use?

## Timeline

- Detection:
- First response:
- Mitigation:
- Rollback or fix:
- Verification:
- User communication:

## Root Cause

Describe the technical and process causes. Include whether tests, release gates,
ownership, platform constraints, or support diagnostics were missing or weak.

## What Went Well

- 

## What Went Poorly

- 

## Corrective Actions

| Action | Owner | Due date | Verification |
| --- | --- | --- | --- |
| Add regression test or release smoke |  |  |  |
| Update runbook/checklist |  |  |  |
| Improve user-facing error or fallback |  |  |  |
| Close privacy/security gap |  |  |  |

## Privacy And Recovery Checklist

- Exposed credentials rotated.
- Affected sessions/devices revoked where needed.
- Remote route probes verified.
- Backup/restore integrity verified.
- Support artifacts redacted.
- Release notes or user guidance published when needed.

## Prevention Review

Update the relevant docs before closing:

- [Production SLO/SLI guide](../production-slo-sli.md)
- [Production readiness review](production-readiness-review-template.md)
- [Rollback and recovery checklist](../rollback-recovery-checklist.md)
- [Platform release and entitlements](../platform-release-and-entitlements.md)
