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
  requirements-runtime.txt    pinned dependencies for the bundled runtime
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
  prepare_python_runtime.ps1  private Python 3.12 runtime preparation
  package_windows.ps1         portable release staging helper
  verify_windows_package.ps1  package lifecycle/readiness smoke check
  build_windows_installer.ps1 Inno Setup compiler wrapper
  verify_windows_installer.ps1 install/upgrade/uninstall smoke check
packaging/windows/
  LeadPilot.iss              Inno Setup installer definition
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
- Gmail Phase 3 uses the official Google endpoints for OAuth, reviewed draft creation, and permitted thread/message synchronization. It requests only `gmail.compose` and `gmail.readonly`; Gmail send endpoints are not called.
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

Flutter and Dart are installed locally at `C:\src\flutter` (Flutter 3.47.7,
Dart 3.13.5), Windows desktop support is enabled, and the Visual Studio Windows
toolchain is verified. A new build machine must include:

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

The mock provider is the only provider that is usable by default, and it never sends. Gmail Phase 3 is draft-only: it never calls Gmail send endpoints. It uses a server-generated one-time state, PKCE S256, and a fresh Desktop-app loopback redirect `http://127.0.0.1:<runtime-port>` for each authorization attempt. The browser callback is handled by that dedicated listener; every FastAPI `/api` route remains token-protected. Microsoft Graph remains a non-live configuration stub. Do not treat environment-variable presence as proof of a working provider.

Before any live campaign, independently verify:

1. Business identity, sender identity, dedicated mailbox/domain, SPF, DKIM, and DMARC.
2. Valid postal address and working unsubscribe destination.
3. Lawful data provenance and suppression-list import.
4. A real provider adapter test using a controlled mailbox and conservative limits.
5. `DRY_RUN=true` and `LIVE_SENDING_ENABLED=false` remain the Phase 3 backend defaults; this phase creates drafts only and does not send.

Secrets belong in a local secret manager or environment configuration, never in chat, source code, `.env` files committed to version control, reports, or logs.

## Important API routes

- `GET /health/live`, `GET /health/ready`
- `GET /api/dashboard/metrics`
- `GET /api/leads?limit=100&offset=0&search=...`
- `GET /api/leads/count`, `GET /api/leads/{id}`, `GET /api/leads/{id}/history`
- `POST /api/leads/import/preview` for bounded CSV/XLSX preview and suggested mapping
- `POST /api/leads/import` for validated direct imports; `POST /api/leads/import/queue` for background imports after preview/mapping
- `GET /api/leads/export.csv`
- `POST /api/leads/{id}/research`
- `POST /api/drafts/generate`, `GET /api/drafts`, `PATCH /api/drafts/{id}` for AI draft review/editing only
- `POST /api/suppressions`, `GET /api/suppressions`
- `POST /api/campaigns`, `POST /api/campaigns/{id}/outreach/preview`, `POST /api/campaigns/{id}/outreach/run`
- `GET /api/jobs/{id}`, `POST /api/jobs/{id}/cancel`, `POST /api/jobs/{id}/retry`
- `POST /api/replies/ingest`, `GET /api/leads/{id}/replies`
- `POST /api/automation/stop`, `POST /api/automation/resume`
- `POST /api/pricing/calculate`
- `POST /api/briefs/generate`
- `GET /api/ai/status`, `GET /api/ai/config`, `GET /api/ai/usage`
- `PATCH /api/ai/config` for non-secret provider settings and `POST /api/ai/connectivity` for a minimal structured provider check
- `POST /api/ai/personalization/preview`, `POST /api/ai/reply-classification/preview`, `POST /api/ai/brief/preview`
- `GET /api/gmail/status`, `GET /api/gmail/health`, `GET /api/gmail/auth-url`
- `POST /api/gmail/drafts/reviewed` (and compatibility path `POST /api/gmail/drafts`) accepts only a local reviewed draft ID; `POST /api/drafts/{id}/gmail` is an equivalent explicit route. It creates a Gmail draft once, records safe provider IDs, and never sends or overwrites a provider draft.
- `POST /api/gmail/sync` paginates permitted thread metadata/body retrieval, deduplicates provider message IDs, records exact lead matches or unknown/ambiguous outcomes, and uses an incremental history cursor with full-resync fallback when Gmail expires it. `POST /api/gmail/disconnect` revokes when possible and deletes local token material. `GET /api/gmail/auth-url` starts a single dedicated loopback listener; the former FastAPI callback path is an authenticated rejection and does not accept OAuth values.
- `GET/POST /api/packages`, `POST /api/packages/recommend`, `POST /api/packages/{id}/profit`
- `GET/POST/PATCH /api/proposals`, `/api/payments`, `/api/renewals`
- `POST/GET /api/follow-ups/queue`, `/api/follow-ups`
- `POST /api/clients`, `GET /api/clients`, `POST /api/projects`, `GET /api/projects`
- `GET /api/providers`, `GET/PATCH /api/settings`, `POST /api/backup`

### AI provider setup and connectivity

The current AI adapter sends OpenAI-compatible JSON requests to
`{AI_BASE_URL}/chat/completions`. The following names are read from the backend
process environment or the non-secret Settings UI fields:

```text
AI_PROVIDER=none                 # any non-none label uses the OpenAI-compatible adapter
AI_MODEL=                        # required when a provider is enabled
AI_BASE_URL=https://api.openai.com/v1
AI_API_KEY=                      # required, environment/secret-store only
AI_TIMEOUT_SECONDS=20
AI_MAX_RETRIES=2
AI_RETRY_BACKOFF_SECONDS=0.25
```

The backend never returns `AI_API_KEY`, stores it in SQLite, writes it to logs,
or accepts it from the Flutter UI. Configure it in the process environment or
an approved local secret manager, for example in a private PowerShell session:

```powershell
$env:AI_PROVIDER = "openai-compatible"
$env:AI_MODEL = "your-model-name"
$env:AI_BASE_URL = "https://api.openai.com/v1"
$env:AI_API_KEY = "<set-this-locally-never-in-chat>"
$env:AI_TIMEOUT_SECONDS = "20"
$env:AI_MAX_RETRIES = "2"
$env:AI_RETRY_BACKOFF_SECONDS = "0.25"
```

Start or restart the backend after changing environment values. In the desktop
Settings screen, the **AI provider configuration** card can display the
sanitized active configuration and save non-secret provider/model/base URL/
timeout/retry values. Use **Test connectivity** to send only a minimal
structured request stating that it is a connectivity check; it does not create
personalized outreach, create a draft, or send email. The result distinguishes
missing configuration, invalid configuration, authentication errors, rate
limits, network failures, timeouts, invalid responses, and other provider
errors. Successful checks are recorded as `connectivity_check` usage events;
prompts, responses, and secrets are not persisted.

AI preview output is validated against strict Pydantic schemas. Provider
requests use bounded retries and the configured timeout. `DRY_RUN=true`,
`LIVE_SENDING_ENABLED=false`, `GMAIL_LIVE_SEND_APPROVED=false`, and
`GMAIL_LIVE_SEND_TESTED=false` remain the safe desktop defaults; Phase 1 adds
no email-send path.

### Phase 2 lead import and draft workflow

Lead import is a two-step desktop workflow:

1. In **Leads & import**, enter a local `.csv` or `.xlsx` path.
2. Select **Import** to upload a bounded preview. Review detected columns,
   sample rows, suggested mappings, row limits, and preview errors.
3. Map the required email column and optional first name, last name, company,
   title, and source columns. Ignored columns are not stored.
4. Queue the import. The backend revalidates the complete file, normalizes
   emails, deduplicates within the upload and against SQLite, checks the global
   suppression table, and reports processed/imported/duplicate/suppressed/
   invalid/skipped counts. Files are limited to 25 MB and 100,000 rows; XLSX
   decompressed content is limited to 100 MB.

Lead records remain searchable and paginated. Selecting a row opens the
operator-review flow for verified website/evidence notes and deterministic
qualification scoring. Scores use only supplied lead fields and explicitly
stored operator-verified research; no web facts are invented. Source and
research evidence remain visible on the lead record, and review actions are
audited.

The **Generate draft** action is available for eligible, non-suppressed leads.
Provide a service/offer brief, tone, and call to action. The configured AI
provider receives only the selected lead fields and verified research fields,
with instructions not to invent company facts, achievements, prior
interactions, or missing details. The structured subject/body response is
validated and stored as a reviewable draft with provider/model/usage metadata.
Drafts can be edited and regenerated; edited content is marked separately from
the original generated subject/body. Phase 2 does not send or schedule email.
Phase 3 adds a separate, explicit reviewed-draft-to-Gmail-draft action; it never
sends or overwrites a provider draft. Suppressed, unsubscribed, replied, or
bounced leads are blocked again immediately before generation, Gmail draft
creation, and outreach preview.

### Phase 3 Gmail setup, scopes, and token storage

Create a **Desktop app** OAuth client in Google Cloud, then set its client ID in
the per-user `config\backend.env` file or the backend process environment. The
launcher permits `GMAIL_CLIENT_ID` but keeps the client secret environment-only.
A client secret is optional for this loopback Desktop flow. Do not set a fixed
`GMAIL_REDIRECT_URI`: each
authenticated `GET /api/gmail/auth-url` binds an available port on
`127.0.0.1`, returns a Google URL containing exactly
`http://127.0.0.1:<runtime-port>`, and uses that same URI in the token exchange.
The server generates the state and PKCE verifier; a caller-supplied `state`
query value is ignored. Google receives the minimum Phase 3 scopes:

```text
https://www.googleapis.com/auth/gmail.compose
https://www.googleapis.com/auth/gmail.readonly
```

`gmail.modify` is not requested. Offline access is used so the local backend can
refresh an authorized session when needed. On Windows, access and refresh tokens
are encrypted with the current user's DPAPI via stdlib `ctypes` and stored only
in the per-user encrypted token file. The backend has no plaintext token-file
fallback and fails closed if DPAPI is unavailable. Tokens are never stored in
SQLite, ordinary settings, API models, logs, or audit details. Tests may inject
an in-memory token store; production uses the DPAPI store.

The dedicated callback listener accepts only its exact root path on
`127.0.0.1`, validates the one-time expiring state and PKCE verifier, and
closes after completion, denial, expiry, or an invalid callback. Callback
responses are deliberately generic. Both required scopes must be present in the
token response and an authorization-code exchange must return a usable refresh
token before credentials are stored. Disconnect attempts Google credential
revocation and securely deletes local token material even when remote
revocation is unavailable.

The Settings screen exposes explicit Connect, Verify, and Disconnect controls;
authorization alone is shown as pending until the profile health check succeeds.
Draft review exposes **Create Gmail Draft** only for a known, eligible lead and
nonempty generated/edited content. Thread synchronization is a separate manual
action, bounded and paginated; it stores minimal message metadata/content for
matching and deduplicates provider message IDs. Email bodies and headers are
treated as untrusted input, attachments are not downloaded, and unknown or
ambiguous lead matches are retained as such.

## Database and backup

SQLite migrations are applied automatically on startup and tracked with `PRAGMA user_version` plus `schema_version` rows. The current schema is migration version 6 and includes leads, suppressions, campaigns, jobs, outreach events, audit logs, alerts, research fields, replies, clients, proposals, projects, payments, renewals, website packages, follow-up queue entries, AI usage events, import batches/errors/provenance, reviewable personalized drafts, and Gmail account/draft-reference/sync/thread/message metadata. Migration 006 contains no token or client-secret columns. The backup endpoint uses SQLite's online backup API and writes to `backend/backups/` by default.

The PostgreSQL/multi-device option is intentionally not enabled in this local release. The repository/service boundaries keep that migration possible without moving business rules into the UI.

Backups are created through the authenticated `POST /api/backup` endpoint. A
restore is intentionally an operator-controlled offline action rather than a
destructive UI button: stop the backend, copy a verified backup over the
configured SQLite file, remove any stale `-wal`/`-shm` sidecars only when the
process is stopped, then start the backend and verify `/health/ready`. Do not
restore over a running database.

## Windows packaging

The Windows work is delivered in small, testable phases. The package staging
directory contains the Flutter release, a private Python 3.12 runtime, pinned
backend runtime dependencies, and installed-layout launch/stop helpers. Phase
2 adds the Inno Setup installer around that staging directory.

After Visual Studio and the Flutter Windows toolchain are available:

```powershell
.\scripts\build_windows.ps1
.\scripts\package_windows.ps1 -PythonExecutable "C:\Path\To\Python312\python.exe"
.\scripts\verify_windows_package.ps1 -PackageDirectory .\dist\leadpilot-windows
.\scripts\build_windows_installer.ps1 -InnoSetupCompiler "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
```

`package_windows.ps1` copies the release output from
`frontend\build\windows\x64\runner\Release`, provisions a self-contained
Python 3.12 directory, and installs the pinned dependencies in
`backend\requirements-runtime.txt`. The build machine needs Python 3.12 and
network access to resolve those pinned wheels; the installed user does not
need Python or Flutter.

For a portable staging run, launch the package with:

```powershell
.\dist\leadpilot-windows\scripts\run_leadpilot.ps1 `
  -InstallRoot .\dist\leadpilot-windows `
  -LaunchFrontend
```

The launcher starts Uvicorn on `127.0.0.1`, waits for `/health/ready`, verifies
an authenticated API request, then starts the packaged Flutter executable. A
random local API token is generated in memory and inherited by both processes;
it is never written to a file, passed on the command line, or printed. Closing
the frontend stops only the backend process owned by that launcher. The
standalone `stop_leadpilot.ps1` helper verifies the recorded executable path
and process start time before stopping anything.

Persistent data is kept outside the replaceable package directory under
`%LOCALAPPDATA%\LeadPilot`:

```text
config\backend.env          user configuration and provider settings
data\leadpilot.db           SQLite database
backups\                    database backups
logs\                       backend stdout/stderr
runtime\backend.process.json process ownership metadata only
```

The installer is built from `packaging\windows\LeadPilot.iss`. It provides an
installation-directory page, a Start Menu shortcut, an unchecked optional
Desktop shortcut, and a checked optional launch-after-install checkbox. Every
shortcut targets Windows PowerShell and `scripts\run_leadpilot.ps1`; shortcuts
never target the Flutter executable directly because the launcher owns backend
startup and the environment-variable authentication contract.

The installer defaults to `C:\Program Files\LeadPilot AI` and rejects an
installation directory that overlaps `%LOCALAPPDATA%\LeadPilot`. The installer
stops only the recorded LeadPilot backend and packaged frontend before an
upgrade or uninstall. It does not add any uninstall rule for user data.

The launcher always enforces `LOCAL_ONLY_API=true`, `DRY_RUN=true`,
`LIVE_SENDING_ENABLED=false`, and disabled Gmail live-send approval flags.
Provider credentials remain environment-only; the launcher does not write them
to the persistent configuration file.
Upgrades replace only the package directory and preserve `%LOCALAPPDATA%\LeadPilot`.
Uninstall stops owned processes, removes application files and shortcuts, and
preserves `%LOCALAPPDATA%\LeadPilot`. Data deletion is intentionally not
offered by the installer; remove it manually only after making a backup and
confirming the path.

After compiling an installer, run the realistic lifecycle verifier on an
isolated Windows machine or runner:

```powershell
.\scripts\verify_windows_installer.ps1 -InstallerPath .\dist\LeadPilot-Setup.exe
```

That check installs into a temporary path containing spaces, validates the
launcher-targeted shortcuts, launches the actual Flutter executable, performs
an upgrade while the backend is running, uninstalls, and confirms the database,
configuration, and marker data remain. It is destructive only inside its
unique temporary test root. If Windows elevation or the runner cannot create
or close a desktop GUI, perform the same test manually: install with the
Desktop shortcut selected, launch from Start Menu, close the window, repeat
while the backend is running, then uninstall and verify that
`%LOCALAPPDATA%\LeadPilot` remains.

GitHub Actions installs Inno Setup 6.7.1 automatically for the installer job.
This workspace also has Inno Setup 6.7.1 installed per-user for local installer
verification, but the unrelated backend and Flutter tests do not require Inno
Setup. On a machine without it, `build_windows_installer.ps1` reports the
missing compiler without affecting those tests.

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
python -m pytest                 86 passed, 1 dependency deprecation warning
python -m compileall -q app tests passed

scripts\test_launcher_config.ps1 passed: GMAIL_CLIENT_ID imports from the
per-user config, client secret and fixed redirect values do not, and launcher
safety overrides remain enforced.
```

An actual backend server smoke check also passed: readiness returned `ready`, database `ok`, migration `6`, and an unauthenticated dashboard request returned `401`. The synthetic smoke workflow also created a lead, rendered a dry-run preview, completed a background job, and read back lead history.

Flutter toolchain status:

```text
Flutter 3.47.7 at C:\src\flutter: verified
Dart 3.13.5: verified
flutter pub get: passed
flutter analyze: passed with no issues
flutter test: passed (18 tests)
flutter build windows --release: passed
```

The frontend is dependency-light and source-complete. macOS builds remain
untested. The Windows package staging check is also verified locally with
Python 3.12.10 and the generated release executable. Installer compilation
and lifecycle verification require Inno Setup; `ISCC.exe` was not available in
this workspace and therefore remain for GitHub Actions.

## Private GitHub CI

The repository now includes `.github/workflows/ci.yml`. It uses three isolated
GitHub-hosted Windows jobs and does not require project secrets:

- `backend`: Python 3.12, editable test installation, `compileall`, and all
  backend pytest cases.
- `flutter`: stable Flutter `3.47.7`, `flutter doctor -v`, `flutter pub get`,
  `flutter analyze`, `flutter test`, and `flutter build windows --release`.
- `package-staging`: repeats the Windows release build, provisions the private
  Python runtime, runs `verify_windows_package.ps1`, installs Inno Setup 6.7.1,
  compiles `LeadPilot-Setup.exe`, runs `verify_windows_installer.ps1`, and
  uploads both the staging archive and the installer artifact.

The installer job installs Inno Setup automatically on `windows-latest`; local
backend and Flutter tests do not require Inno Setup.

The Phase 3 Desktop OAuth changes have not been pushed, so GitHub Actions has
not run against this working tree.

### Repository state

This workspace is connected to the private GitHub repository
`vanshvashistha44657/leadpilot-ai` on `main`. Do not commit provider secrets,
SQLite databases, runtime logs, generated `dist/` output, or local `.env`
files. Review `git status --short` and the staged file list before every push.

```powershell
git status --short
git diff --check
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
