# LeadPilot AI

LeadPilot AI is a local-first desktop sales-automation workspace for selling websites to US businesses. It uses a Flutter/Dart desktop console and a modular Python/FastAPI automation engine backed by SQLite. The default operating mode is **dry-run** and the API binds to `127.0.0.1` when started with the documented command.

The workspace was empty and no dataset, business identity, sender mailbox, or API credentials were available. Therefore provider integrations are intentionally unconfigured, and no live email, paid service, or public deployment is enabled.

## Current repository

```text
backend/
  app/
    api/routes.py             FastAPI endpoints and safety controls
    services/                 imports, jobs, outreach, research, pricing, providers, AI, Gmail
    migrations/*.sql          versioned SQLite migrations
    repositories.py           persistence boundary
  tests/                      pytest API and service tests
  pyproject.toml
  .env.example
frontend/
  lib/                        Flutter desktop UI, typed API client, screens
  pubspec.yaml                Flutter SDK-only dependencies
  README.md
scripts/
  run_backend.ps1             local backend launcher
  run_leadpilot.ps1           backend readiness/process manager and optional Flutter launch
  stop_leadpilot.ps1          backend process stop helper
  build_windows.ps1           reproducible Flutter Windows build helper
  package_windows.ps1         portable release staging helper
```

## Implemented safe workflows

- CSV and XLSX lead import with streaming/batched normalization, email validation, deduplication, source provenance, and suppression checks.
- Persisted lead status, operator-verified research fields, opportunity scoring, paginated search, and streamed CSV export.
- Background job queue with persisted status, progress, cancellation requests, retries, and queued large-file imports.
- Campaign creation, placeholder rendering, preview, dry-run outreach, audit events, and suppression/replied/bounced follow-up stops.
- Reply ingestion with deterministic classification for unsubscribe, bounce, pricing, meeting, interested, and other replies; opt-outs are suppressed and high-intent replies create alerts.
- Dashboard metrics for leads, campaigns, dry-run/live events, jobs, replies, high-intent replies, reviewed leads, clients, and projects.
- Pricing/profit calculation for delivery costs, platform fees, revenue, expected conversions, net profit, and margin.
- Client and fulfillment records for projects, previews, deployments, domains, hosting/database plans, revisions, and renewals-ready status fields. URLs are recorded only; deployment is never claimed without a provider confirmation.
- Deterministic client website brief/Lovable prompt generation without pretending that a Lovable project was created.
- Configurable OpenAI-compatible LLM interface for personalization, reply classification, and brief generation; it remains unavailable until an environment-only provider key/model are configured, and records usage/cost metadata when called.
- Gmail OAuth/API boundary using official Google endpoints, external token storage, sender/profile health checks, drafts, thread synchronization, and hard live-send gates. No live-capable state is claimed without OAuth, sender configuration, explicit approval, and a controlled integration-test marker.
- Deterministic website package recommendations, recurring revenue/profit calculations, proposal/payment/renewal tracking, and dry-run-only follow-up queueing with reply/bounce/unsubscribe exclusion.
- Local authenticated API using `X-Local-Token`, JSON structured logging, SQLite WAL mode, migration tracking, and database backup endpoint.
- Global automation stop/resume control that blocks new automation work and requests cancellation of queued/running jobs.
- Flutter screens for overview, leads/import, campaigns, clients/projects, pricing, fulfillment, alerts, and settings with light/dark themes and explicit dry-run state.

## Backend setup

Requires Python 3.12+.

```powershell
cd backend
python -m pip install -e ".[test]"
python -m pytest
python -m compileall -q app tests
```

`backend/.env.example` is a variable template; the backend currently reads
process environment variables directly and does not load a `.env` file. Use
PowerShell `$env:NAME = "value"`, a secret manager, or the provided launcher
script rather than assuming that copying the template changes runtime config.

Run the local API:

```powershell
cd backend
$env:LOCAL_TOKEN = "replace-with-a-long-random-local-token"
$env:DRY_RUN = "true"
$env:LIVE_SENDING_ENABLED = "false"
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

For a managed local process with readiness polling and log files:

```powershell
cd "C:\Users\vansh\Desktop\ai automation for cold mailing"
.\scripts\run_leadpilot.ps1
# Later:
.\scripts\stop_leadpilot.ps1
```

After the Flutter/Windows toolchain is installed, use
`.\scripts\run_leadpilot.ps1 -LaunchFlutter` to start the backend and run the
desktop app with matching localhost URL/token environment variables.

OpenAPI is available at `http://127.0.0.1:8000/docs`. Authenticated API calls require:

```text
X-Local-Token: <LOCAL_TOKEN>
```

The unauthenticated liveness/ready endpoints are intentionally not used to access business data; all `/api/*` endpoints require the local token.

## Flutter setup and Windows run

Flutter and Dart are now installed locally at `C:\src\flutter` (Flutter
3.47.7, Dart 3.13.5) and Windows desktop support is enabled. Visual Studio's
installer is open, but `vswhere` does not yet report a completed Visual Studio
Community installation, so the Windows C++ build remains blocked until the
workload finishes. The installation must include:

1. Install the stable Flutter SDK from <https://docs.flutter.dev/get-started/install/windows/desktop> and extract it to a path such as `C:\src\flutter` (avoid protected directories).
2. Add `C:\src\flutter\bin` to the user `PATH`, then open a new PowerShell window.
3. Complete Visual Studio Community 2026 installation with **Desktop development with C++**, MSVC, CMake tools, and a Windows 10/11 SDK.
4. Verify the toolchain before changing the project:

```powershell
flutter doctor
flutter config --enable-windows-desktop
flutter doctor -v
```

Then configure and run the application:

```powershell
cd frontend
flutter create --platforms=windows --empty .  # generate Windows runner once; preserves lib/
flutter pub get
$env:LEADPILOT_API_URL = "http://127.0.0.1:8000"
$env:LEADPILOT_LOCAL_TOKEN = "replace-with-a-long-random-local-token"
flutter run -d windows
```

The app reads the API URL and local token from the process environment and keeps them in memory. Configure them in the Settings screen when required. The current UI has no third-party runtime packages.

## Provider configuration

The mock provider is the only provider that is usable by default, and it never sends. Gmail now has an official OAuth/API boundary for authorization, token refresh, sender/profile health, drafts, sends, and thread synchronization, but live capability remains blocked until OAuth, sender configuration, `GMAIL_LIVE_SEND_APPROVED=true`, `GMAIL_LIVE_SEND_TESTED=true`, compliance gates, and a controlled integration test are complete. Microsoft Graph remains a non-live configuration stub. Do not treat environment-variable presence as proof of a working provider.

Before any live campaign, independently verify:

1. Business identity, sender identity, dedicated mailbox/domain, SPF, DKIM, and DMARC.
2. Valid postal address and working unsubscribe destination.
3. Lawful data provenance and suppression-list import.
4. A real provider adapter test using a controlled mailbox and conservative limits.
5. `DRY_RUN=false`, `LIVE_SENDING_ENABLED=true`, compliance acknowledgement, and an explicit operator approval process.

Secrets belong in a local secret manager or environment configuration, never in chat, source code, `.env` files committed to version control, reports, or logs.

## Important API routes

- `GET /health/live`, `GET /health/ready`
- `GET /api/dashboard/metrics`
- `GET /api/leads?limit=100&offset=0&search=...`
- `GET /api/leads/count`, `GET /api/leads/{id}`, `GET /api/leads/{id}/history`
- `POST /api/leads/import` for direct small imports; `POST /api/leads/import/queue` for background imports
- `GET /api/leads/export.csv`
- `POST /api/leads/{id}/research`
- `POST /api/suppressions`, `GET /api/suppressions`
- `POST /api/campaigns`, `POST /api/campaigns/{id}/outreach/preview`, `POST /api/campaigns/{id}/outreach/run`
- `GET /api/jobs/{id}`, `POST /api/jobs/{id}/cancel`, `POST /api/jobs/{id}/retry`
- `POST /api/replies/ingest`, `GET /api/leads/{id}/replies`
- `POST /api/automation/stop`, `POST /api/automation/resume`
- `POST /api/pricing/calculate`
- `POST /api/briefs/generate`
- `GET /api/ai/status`, `GET /api/ai/config`, `GET /api/ai/usage`
- `POST /api/ai/personalization/preview`, `POST /api/ai/reply-classification/preview`, `POST /api/ai/brief/preview`
- `GET /api/gmail/status`, `GET /api/gmail/health`, `GET /api/gmail/auth-url`, `GET /api/gmail/oauth/callback`
- `GET/POST /api/packages`, `POST /api/packages/recommend`, `POST /api/packages/{id}/profit`
- `GET/POST/PATCH /api/proposals`, `/api/payments`, `/api/renewals`
- `POST/GET /api/follow-ups/queue`, `/api/follow-ups`
- `POST /api/clients`, `GET /api/clients`, `POST /api/projects`, `GET /api/projects`
- `GET /api/providers`, `GET/PATCH /api/settings`, `POST /api/backup`

## Database and backup

SQLite migrations are applied automatically on startup and tracked with `PRAGMA user_version` plus `schema_version` rows. The current schema is migration version 4 and includes leads, suppressions, campaigns, jobs, outreach events, audit logs, alerts, research fields, replies, clients, proposals, projects, payments, renewals, website packages, follow-up queue entries, and AI usage events. The backup endpoint uses SQLite's online backup API and writes to `backend/backups/` by default.

The PostgreSQL/multi-device option is intentionally not enabled in this local release. The repository/service boundaries keep that migration possible without moving business rules into the UI.

Backups are created through the authenticated `POST /api/backup` endpoint. A
restore is intentionally an operator-controlled offline action rather than a
destructive UI button: stop the backend, copy a verified backup over the
configured SQLite file, remove any stale `-wal`/`-shm` sidecars only when the
process is stopped, then start the backend and verify `/health/ready`. Do not
restore over a running database.

## Windows packaging

After Visual Studio finishes installing and generating Windows runners if needed:

```powershell
cd frontend
flutter create --platforms=windows --empty .
flutter build windows --release
```

`scripts/build_windows.ps1` checks for Flutter, generates a missing Windows runner with the empty template (so it does not add a stock app/test), runs `flutter pub get`, `flutter analyze`, `flutter test`, and produces the release build. `scripts/package_windows.ps1` stages a verified Flutter release alongside the backend source and configuration template, but does not sign binaries or create an installer. A production installer still needs a selected packaging strategy (MSIX/Inno Setup/WiX), embedded Python runtime policy, firewall rules for localhost, code signing, upgrade/migration handling, and a release test on a clean Windows machine.

The verified Flutter output, once the command succeeds, is
`frontend\build\windows\x64\runner\Release`. For an installer, stage the
Flutter release plus the selected Python 3.12 runtime, backend package, a
launcher that starts Uvicorn on `127.0.0.1` with a generated local token, and a
shutdown handler. Then package that staging directory with MSIX, Inno Setup,
or WiX and test install/upgrade/uninstall on a clean Windows VM. The Python
runtime bundling and code-signing steps are intentionally not claimed as
verified here.

## macOS plan

Build on a compatible macOS host:

```bash
cd frontend
flutter create --platforms=macos .
flutter pub get
flutter build macos --release
```

Then create the `.app`/`.dmg`, bundle or provision the Python backend, isolate macOS-specific process/storage code, sign, notarize, and test on a clean supported macOS version. No macOS build was run or verified in this environment.

## Cloud worker and future integrations

The local queue is process-local with persisted job state. It is suitable for a single desktop process, not for multi-device scheduling. The next production phase should move scheduled jobs to a durable PostgreSQL-backed queue/worker, add provider webhooks for replies/bounces, encrypt secrets with OS keychain storage, add team/tenant authorization, and implement tested Gmail/Graph/LLM/Lovable adapters. Phone calling, billing, CRM sync, and public deployment remain opt-in extensions.

## Verification performed in this workspace

From `backend/`:

```text
python -m pytest                 36 passed, 1 dependency deprecation warning
python -m compileall -q app tests passed
```

An actual backend server smoke check also passed: readiness returned `ready`, database `ok`, migration `4`, and an unauthenticated dashboard request returned `401`. The synthetic smoke workflow also created a lead, rendered a dry-run preview, completed a background job, and read back lead history.

Flutter toolchain status:

```text
Flutter 3.47.7 at C:\src\flutter: verified
Dart 3.13.5: verified
flutter pub get: passed
flutter analyze: passed with no issues
flutter test: blocked before execution by Windows Application Control/WDAC when launching flutter_tester.exe
flutter build windows --release: blocked because Visual Studio C++ toolchain is not yet registered by vswhere
```

The frontend is dependency-light and source-complete. A verified Windows desktop build still requires the Visual Studio installation to finish and the local Application Control policy to allow `C:\src\flutter\bin\cache\artifacts\engine\windows-x64\flutter_tester.exe` for Flutter tests. macOS builds remain untested.

## Private GitHub CI

The repository now includes `.github/workflows/ci.yml`. It uses two isolated
GitHub-hosted Windows jobs and does not require project secrets:

- `backend`: Python 3.12, editable test installation, `compileall`, and all
  backend pytest cases.
- `flutter`: stable Flutter `3.47.7`, `flutter doctor -v`, `flutter pub get`,
  `flutter analyze`, `flutter test`, and `flutter build windows --release`.

The CI runner is separate from the local Windows machine, so the local
Smart App Control/WDAC block on `flutter_tester.exe` is not disabled or
modified. CI results are only authoritative after the workflow runs on GitHub;
no CI result is claimed from this workspace before a push.

### Create a private repository without publishing from this CLI

The current workspace is not a Git repository and has no configured remote.
The following commands are instructions for the operator; they were not run:

```powershell
cd "C:\Users\vansh\Desktop\ai automation for cold mailing"
git init -b main
git config user.name "Your Name"
git config user.email "you@example.com"
git status --short
```

Before staging, inspect the output and confirm that no dataset, SQLite file,
runtime log, `dist/` output, `.env`, OAuth token, API key, or other private
material appears. The root `.gitignore` excludes generated build/staging output
and backend runtime data, but the operator should still review `git status`.

Create an empty **private** repository through GitHub's website, then connect
and push only after reviewing the staged file list:

```powershell
git remote add origin https://github.com/<owner>/<private-repository>.git
git add .github README.md .gitignore backend frontend scripts
git status --short
git commit -m "ci: add Windows Flutter and backend checks"
git branch -M main
git push -u origin main
```

Alternatively, after installing and authenticating GitHub CLI with `gh auth
login`, the equivalent private-repository command is:

```powershell
gh repo create <owner>/<private-repository> --private --source=. --remote=origin --push
```

That `gh` command was not run. Do not use `--public`, do not paste secrets in
workflow files, and do not commit `backend/.env` or provider token files. After
the push, open the repository's **Actions** tab and inspect the `LeadPilot CI`
run. Pull requests will run the same checks before merge.
