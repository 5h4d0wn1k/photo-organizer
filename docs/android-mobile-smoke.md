# Android Mobile Smoke Runbook

This runbook validates the private beta path with one Linux laptop daemon and two physical Android phones.

## Preconditions

- Two Android phones are connected by USB, unlocked, and authorized in `adb devices -l`.
- Both phones are on the same trusted LAN or laptop hotspot as the Linux laptop.
- The Rust daemon is running in explicit LAN development mode:

```bash
PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 scripts/private_gallery_mobile_lan_daemon.sh
```

- Use the laptop LAN or hotspot URL as the device URL, for example `http://10.71.158.49:4821`.
- Remote boundary must hold from the phones: `/health` returns `200`; `/library/status` and `/pairing/sessions` return `403`.

## Deterministic API Smoke

Run this first. It uses a temporary Dex HTTP helper on each phone and does not touch real camera-roll media.

```bash
PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=http://<laptop-lan-ip>:4821 \
PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT=2 \
scripts/android_mobile_smoke.sh
```

Optional controls:

- `PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS="serial1 serial2"` fixes device order and excludes other authorized devices.
- `PRIVATE_GALLERY_SMOKE_PAYLOAD_BYTES=3145728` sets the synthetic payload size. It must stay larger than `2097152`.
- `PRIVATE_GALLERY_SMOKE_CHUNK_BYTES=1048576` sets chunk size. It must be smaller than the payload and no larger than `8388608`.
- `PRIVATE_GALLERY_SMOKE_EXPECT_REMOTE_BOUNDARY=true` forces LAN boundary checks even if the URL looks loopback-like.

Acceptance:

- Exactly two requested phones pair successfully.
- Each phone uploads a large chunked fixture, resumes after the first chunk, rejects overlapping chunks, dedupes a duplicate upload, and rejects chunks after cancel.
- Before revocation, each phone sees, searches, and downloads each phone's uploaded asset.
- SHA-256 for ranged original and preview downloads matches the uploaded payload.
- Mobile session refresh returns a replacement bearer token, and the previous bearer is rejected immediately.
- Mobile session lists do not expose token hashes.
- Revoking one session rejects that bearer while the other phone remains valid.
- Device-session revocation rejects all sessions for that device.

## Flutter App Smoke

Run this after the API smoke. It builds and installs the debug Android app, clears app state by default, grants media/camera permissions where Android allows it, creates one pairing token per phone, and attempts to drive the visible Flutter pairing flow with `uiautomator`.

```bash
PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=http://<laptop-lan-ip>:4821 \
PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS="serial1 serial2" \
scripts/android_mobile_app_smoke.sh
```

Useful controls:

- `PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=direct` is the default. It creates a normal mobile session through the daemon, launches the debug APK with that session, and verifies the app wrote a non-secret pairing marker. This is debug-only and is not available in profile/release builds.
- `PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=ui` drives the visible Flutter pairing flow with `uiautomator`.
- `PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=manual` prints per-phone manual pairing steps.
- `PRIVATE_GALLERY_APP_SMOKE_AUTODRIVE=0` prints manual pairing steps when `PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=ui`.
- `PRIVATE_GALLERY_APP_SMOKE_CLEAR_DATA=0` keeps existing app secure-storage state.
- `PRIVATE_GALLERY_APP_SMOKE_UPLOAD_NEWEST=1` attempts to tap the real camera-roll upload action after pairing.

Manual real-media acceptance:

- On each phone, pair through the LAN invite.
- Confirm the paired workspace shows `Same-network sync active`, `Paired locally`, or `Check session`.
- Tap `Upload newest item` using an intentional test photo/video.
- Refresh both phones and the laptop; the uploaded item from each phone should be visible/searchable on both phones.
- Download one original on each phone and confirm the app does not lose the paired session after restart.

## Current Limit

Native Android Iroh/background vault sync is not part of this smoke. Android private beta sync is the authenticated `/mobile/*` upload/download path through the paired desktop daemon. Desktop-to-desktop encrypted chunk sync remains covered by Rust tests.
