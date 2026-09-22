# Desktop Development

## Purpose

This repository ships generated Flutter runners for Linux, macOS, and Windows. The app code can be analyzed and tested anywhere Flutter runs, but native desktop builds still depend on host-specific toolchains.

## Linux

Required host tools:

- `cmake`
- `ninja`
- `g++`
- `pkg-config`
- `gtk+-3.0` development headers

Typical validation commands:

```bash
cd app
flutter analyze
flutter test
flutter build linux
```

Build a local release bundle that includes both the Flutter app and the Rust
daemon:

```bash
scripts/build_linux_release.sh
```

Install a local app-menu launcher for this checkout:

```bash
scripts/install_linux_desktop_entry.sh
```

The generated launcher starts the bundled `galleryd` first when present, falls
back to local Cargo build outputs, waits for
`http://127.0.0.1:4821/health`, writes logs under `runtime/`, then opens
`app/build/linux/x64/release/bundle/private_gallery_app`.

## macOS

Required host tools:

- Xcode
- Xcode command line tools
- Flutter macOS desktop support enabled

Typical validation commands:

```bash
cd app
flutter build macos
```

## Windows

Required host tools:

- Visual Studio with Desktop development for C++
- CMake
- Ninja or MSBuild-compatible tooling
- Flutter Windows desktop support enabled

Typical validation commands:

```powershell
cd app
flutter build windows
```

## Local API Dependency

The desktop app expects the Rust daemon on `http://127.0.0.1:4821`. It can try to start the daemon automatically on desktop, but manual startup is also supported:

```bash
cargo run --manifest-path native_core/Cargo.toml --bin galleryd
```
