# Rollback And Recovery Checklist

## Scope

Use this checklist when a public release threatens privacy, data integrity,
startup reliability, import correctness, mobile sync, revocation, backup, or
restore. Recovery must stay local-first and non-destructive: do not overwrite an
active library, do not upload private data to hosted services, and do not delete
evidence unless the release owner explicitly approves a cleanup step.

## Immediate Triage

- [ ] Name the incident owner and release owner.
- [ ] Record the release version, commit SHA, platform, and install channel.
- [ ] Freeze further rollout or staged release expansion.
- [ ] Preserve logs, job records, and command output needed to understand the
      issue. Redact secrets, bearer tokens, pairing tokens, vault keys, GPS
      metadata, OCR text, embeddings, and private file paths before sharing.
- [ ] Classify the failure:
  - [ ] Privacy or secret exposure.
  - [ ] Remote desktop-route exposure.
  - [ ] Data loss or corruption.
  - [ ] Startup or daemon health regression.
  - [ ] Import, dedupe, or encrypted vault regression.
  - [ ] Mobile pairing, upload, download, or revocation regression.
  - [ ] Backup verify or restore staging regression.

## Stop Exposure

- [ ] Disable any Tailscale Serve or reverse proxy route except the paths needed
      for emergency confirmation.
- [ ] For LAN development mode, stop the daemon started with
      `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1`.
- [ ] Confirm remote clients cannot reach desktop control routes:

  ```bash
  curl -i https://<remote-base>/library/status
  curl -i https://<remote-base>/pairing/sessions
  ```

- [ ] Revoke affected mobile sessions or devices from the app when auth exposure
      is suspected.
- [ ] Rotate any exposed service credentials, signing keys, bootstrap secrets, or
      tokens before resuming release work.

## Desktop Rollback

- [ ] Identify the last known good release artifact and matching commit.
- [ ] Stop the current launcher and daemon.
- [ ] Install or launch the last known good bundle.
- [ ] Confirm local health:

  ```bash
  curl -fsS http://127.0.0.1:4821/health
  ```

- [ ] Open the app against a test library before asking users to reopen personal
      libraries.
- [ ] If schema or library format changed, do not downgrade a real user library
      until compatibility has been confirmed from docs or a tested fixture.

## Android Rollback

- [ ] Pause staged rollout or unpublish the affected Android artifact.
- [ ] Publish the last known good build to the same track when appropriate.
- [ ] Ask affected users to avoid re-pairing until the rollback build is
      installed.
- [ ] Revoke affected sessions if the failure touches bearer storage, pairing, or
      route authorization.
- [ ] Re-run two-phone API smoke before resuming rollout.

## Library Recovery

- [ ] Do not run destructive cleanup against the active library.
- [ ] Run backup verification from the app or API if the daemon can start.
- [ ] If backup export is needed, write it outside the active library root.
- [ ] Plan restore into a fresh staging root only.
- [ ] Confirm the staged restore contains expected database, originals, encrypted
      vault chunks, and manifest entries.
- [ ] Compare staged content to the active library manually before replacing any
      user-managed files.
- [ ] If vault chunks or keys are missing, report the missing material clearly.
      Do not fall back to untracked plaintext copies.

## Data Integrity Checks

- [ ] Confirm import jobs did not create duplicate assets for the same checksum.
- [ ] Confirm canceled or interrupted mobile uploads did not produce completed
      assets.
- [ ] Confirm available originals can be read through bounded range downloads.
- [ ] Confirm encrypted chunks pass ciphertext hash verification before decrypt
      or restore.
- [ ] Confirm reference imports are still marked external and are not represented
      as protected managed originals.

## Resume Criteria

Resume rollout only after all applicable items are true:

- [ ] Root cause is understood and documented.
- [ ] The fixed or rollback build passes `scripts/production-readiness-check.sh`.
- [ ] Mobile releases pass two-phone API smoke.
- [ ] Backup verify and restore staging pass on an encrypted fixture.
- [ ] Remote boundary probes return expected results.
- [ ] Exposed secrets have been rotated.
- [ ] Release notes describe affected versions, user action, and remaining
      limits without revealing sensitive data.

## After Action

- [ ] Add or update a regression test, release smoke, or manual checklist item.
- [ ] Capture the final user-facing guidance.
- [ ] Record skipped checks and accepted residual risk.
- [ ] Close the incident only after support channels show no active data-loss,
      privacy, or restore reports for the release window.
