# Tandav — Dance Studio Management System

Flutter mobile app + FastAPI backend + PostgreSQL. Dark black/gold "Tandav" theme.
No external services (no WhatsApp, no payment gateway, no Firebase).

## Folder structure

```
Tandav/
├── backend/                  # FastAPI application
│   ├── app/
│   │   ├── main.py           # FastAPI app, CORS, /uploads static, /health
│   │   ├── core/             # config (env), security (JWT+bcrypt), formatting
│   │   ├── db/               # session, Base
│   │   ├── models/           # User, Batch, Student, Attendance, MonthlyAttendance,
│   │   │                     # Fee, Event, EventParticipation, MonthlyProgress
│   │   ├── schemas/          # auth, batch, student, attendance, fee, event, progress, dashboard
│   │   ├── api/v1/           # auth, batches, students, attendance, fees, events, progress, dashboard, reports
│   │   ├── api/deps.py       # JWT dependency, current user
│   │   └── seed.py           # demo data (explicit: python -m app.seed)
│   ├── alembic/              # migrations (initial_schema: 10 tables)
│   ├── tests/                # conftest + test_api — 40 tests, all passing
│   ├── requirements.txt
│   └── .env.example          # documented env vars (no real secrets)
├── mobile/                   # Flutter app (android + web)
│   ├── lib/
│   │   ├── main.dart         # RootGate → Login / HomeShell (AuthState)
│   │   ├── core/             # api_client (10.0.2.2 for emulator), auth_state,
│   │   │                     # theme (TandavColors/TandavTheme), services (TandavApi), format (Fmt/Alert)
│   │   ├── models/           # user, batch, student, attendance, fee, event, progress, dashboard
│   │   ├── widgets/states.dart  # LoadingView, ErrorView, EmptyView, StatusBadge, GoldButton
│   │   └── screens/          # login, home_shell (6 tabs + overflow), dashboard, students,
│   │                         # batches, attendance (daily + monthly), fees, events,
│   │                         # progress, reports
│   └── test/widget_test.dart # 7 unit/widget tests, all passing
└── scripts/e2e_smoke.py      # end-to-end API smoke test (login → CRUD → reports → cleanup)
```

APK artifact: `mobile/build/app/outputs/flutter-apk/app-debug.apk`

## Tech stack & dependencies

| Layer      | Stack                                                            |
|------------|------------------------------------------------------------------|
| Backend    | Python 3.12, FastAPI, Uvicorn, SQLAlchemy 2, Alembic, psycopg2, PyJWT, bcrypt, pydantic-settings, pytest+httpx |
| Mobile     | Flutter 3.44 / Dart 3.12; http, provider, shared_preferences, intl, image_picker, flutter_lints |
| Database   | PostgreSQL (project-local cluster, port 5433, user `tandav`)     |

## Database schema (10 tables)

`users` · `batches` · `students` · `attendance` · `monthly_attendance` · `fees` ·
`events` · `event_participations` · `monthly_progress`

Key semantics:
- `students.batch_id` → `batches.id` **SET NULL** (deleting a batch leaves students as "Unassigned" rather than losing them); all student children (attendance, monthly_attendance, fees, participations, progress) **CASCADE** on student delete.
- `fees.amount_paid` is additive — each recorded payment increments it; `status` derived from due vs paid (due / partial / paid).
- `event_participations.costume_fee_paid` additive; `costume_status` derived.
- `MonthlyAttendance` aggregates recomputed after every daily attendance save.
- `monthly_progress.attendance_percentage` auto-synced from the month's attendance.

## API endpoints (all under `/api/v1`, JWT bearer)

| Group | Endpoints |
|-------|-----------|
| auth  | POST `/auth/login` · GET `/auth/me` · POST `/auth/change-password` |
| batches | GET/POST `/batches` · GET/PUT/DELETE `/batches/{id}` |
| students | GET/POST `/students` (search/filter) · GET/PUT/DELETE `/students/{id}` · POST `/students/{id}/photo` |
| attendance | GET/PUT `/attendance/day` · POST `/attendance/day/{id}/status` · DELETE `/attendance/day/{id}` · GET `/attendance/monthly` · GET `/attendance/students/{id}/monthly` |
| fees | GET `/fees` (filters/status) · GET `/fees/summary` · POST `/fees/students/{sid}/{month}` · GET/PUT/DELETE `/fees/{id}` · PUT `/fees/{id}/payment` |
| events | GET/POST `/events` · GET/PUT/DELETE `/events/{id}` · GET/POST `/events/{id}/participants` · POST `/events/{id}/participants/batch/{bid}` · GET `/events/{id}/costume-summary` · PUT/DELETE `/events/participants/{pid}` · GET `/events/students/{sid}/history` |
| progress | POST/GET `/progress/students/{sid}` · GET/PUT/DELETE `/progress/students/{sid}/{month}` · GET `/progress` |
| dashboard | GET `/dashboard` (stats + fees + attendance trend + upcoming events + recent students) |
| reports | GET `/reports/monthly` (per-batch attendance + fees, incl. Unassigned) |

## Authentication flow
- Login → JWT (access token) via bcrypt-verified credentials → token stored in `shared_preferences`; every API call sends `Authorization: Bearer <token>`; 401 anywhere → auto-logout to login screen.
- Admin bootstrap only via seed: `admin` / `admin123` (change after first login).
- All secrets (JWT key, DB URL, admin seed password) come from env vars documented in `backend/.env.example` — none hardcoded.

## Flutter screens
Login · Dashboard (stats/fees/attendance trend/upcoming events) · Students (search, filters, list, form, detail with photo upload, fees, progress, attendance) · Batches (list/form/detail) · Attendance (daily batch editor with present/absent/late, monthly summary) · Fees (monthly list, record payment sheet, summary) · Events (list/form/detail with participant management + costume fee payments) · Progress (month ratings 0–100 + remarks) · Reports (monthly per-batch) · Home shell: 6 tabs + overflow menu (Reports, Sign out).

## Run instructions

Backend:
```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# PostgreSQL already running on port 5433 (cluster /home/jagan/tandav_pgdata, user tandav)
alembic upgrade head            # migrate
python -m app.seed              # demo data (optional; server never auto-seeds)
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Mobile (Android):
```bash
cd mobile
cmd.exe /c "C:\Users\jagan\develop\flutter\bin\flutter.bat run"  # emulator; base URL auto = 10.0.2.2:8000
cmd.exe /c "C:\Users\jagan\develop\flutter\bin\flutter.bat build apk --debug"
```

Tests:
```bash
cd backend && .venv/bin/python -m pytest tests/     # 40 passed
cd mobile  && cmd.exe /c "...\flutter.bat test"     # 7 passed
cd ../.. && backend/.venv/bin/python scripts/e2e_smoke.py   # live E2E vs running API (requires server on :8000)
```

## Verification performed
- Alembic migration applied; 10 tables created. Seed: 4 batches, 38 students, 3 events, admin user.
- Backend unit/API suite: **40 passed** (auth, CRUD, photo upload, attendance math, fee payment + history, overpay rejection, events incl. batch/individual participation + costume, progress sync, dashboard, monthly reports, search/filters).
- `flutter analyze` — 0 errors, 0 warnings (35 info-level lints).
- `flutter test` — 7 passed.
- `flutter build apk --debug` — built (Gradle 9.1.0 distribution had to be pulled via WSL and injected into the Windows Gradle cache; subsequent builds ~9s).
- Live E2E smoke (scripts/e2e_smoke.py) — 14 steps all passed: login → dashboard → create batch/student → daily attendance (100%) → monthly summary → fee record + 2 payments (partial → paid) → event + participant + costume fee partial → progress record (overall = mean of ratings, attendance% synced) → related-data queries → monthly report → wrong-password rejected → cascade cleanup verified.
  - The E2E caught and fixed a real app bug: `month` params (fees/dashboard/reports/progress) were sent as `YYYY-MM` while the API types them as full dates — now normalized to `YYYY-MM-01` in `services.dart` (`_monthIso`). Rebuilt APK after the fix.

## Known limitations / notes
- Batch deletion keeps students (FK SET NULL) — they become "Unassigned"; delete students individually to remove them. This is intentional and covered by the monthly report's Unassigned row.
- Admin password `admin123` is seed-only; change it via the change-password endpoint (no dedicated UI).
- Android emulator targets `10.0.2.2:8000`; a physical device needs the LAN IP (edit `api_client.dart`).
- No photo size limits server-side beyond request limits; uploads stored under `UPLOAD_DIR` and served at `/uploads`.
- Seed data is date-relative to the current month (July 2026 fees/attendance seeded; August intentionally empty so a fresh month starts clean).
- `flutter analyze` info lints remain (deprecated `value:` on dropdowns kept intentionally for controlled behavior, null-aware suggestions, etc.).
- E2E leftover data: deleting the smoke batch leaves orphaned "Smoke Student" records (SET NULL behavior); delete them via the students API if they appear.