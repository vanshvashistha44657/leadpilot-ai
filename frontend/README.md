# LeadPilot AI frontend

This directory contains the Flutter/Dart desktop shell for LeadPilot AI. It is
designed for Windows and macOS and uses only the Flutter SDK plus Dart's
standard `dart:io` HTTP and file APIs. No third-party runtime packages are
required.

## Run locally

On Windows, install the stable Flutter SDK, Visual Studio Community (Desktop
development with C++ workload, MSVC, CMake tools, and a Windows SDK), and then
verify the toolchain:

```text
flutter doctor -v
flutter config --enable-windows-desktop
```

From this directory run:

```text
flutter create --platforms=windows --empty .  # Windows build machine
# On macOS, use: flutter create --platforms=macos .
flutter pub get
flutter config --enable-windows-desktop   # Windows, once
flutter config --enable-macos-desktop     # macOS, once
flutter run -d windows                    # or: flutter run -d macos
```

The app defaults to `http://127.0.0.1:8000` and sends the backend token in the
`X-Local-Token` header. The default token is `local-development-token`, matching
the backend's local development default. Both the API base URL and token can be
changed in **Settings → API connection**. Values are kept in memory for the
current process and are not written to disk.

The settings screen also verifies the configured connection against the real
backend. Screens use real API responses and surface loading, empty, and error
states; they do not fabricate successful integrations. CSV/XLSX import accepts
a local file path to avoid adding a file-picker dependency and queues the work
through the backend job system.

## Backend endpoints used

The client maps the backend's `/api` routes for dashboard metrics, leads and
CSV/XLSX imports, campaigns/outreach previews and jobs, clients/projects,
pricing, settings/providers, fulfillment briefs, alerts, audit logs, and
database backups. It also exposes typed AI/Gmail readiness models and the
pricing package library; AI personalization only runs through the configured
backend provider, while Gmail live sending remains backend-gated. Outreach
actions in this shell are explicitly dry-run only.

The current Windows workspace has Flutter 3.47.7, Dart 3.13.5, and the Visual
Studio Windows toolchain installed. `flutter analyze`, `flutter test`, and
`flutter build windows --release` have passed. The packaged desktop shell
receives `LEADPILOT_API_URL` and `LEADPILOT_LOCAL_TOKEN` from the installed
PowerShell launcher; do not launch `leadpilot_frontend.exe` directly for an
installed run.
