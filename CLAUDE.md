# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TechPie is a Flutter app providing third-party campus services for ShanghaiTech University. It supports Android, iOS, Linux, macOS, and HarmonyOS NEXT (OHOS). The backend API lives at `techpie.geekpie.club/api` (prod) / `localhost:3000` (dev toggle in settings).

## Two Flutter SDKs

The project requires **two separate Flutter SDK checkpoints** depending on the build target:

- **Upstream Flutter** (`~/dev/flutter`) — for Linux, Android, iOS, macOS, Windows, web builds. The OHOS fork's gen_snapshot crashes on Linux x64 AOT.
- **OHOS Flutter fork** (`~/dev/flutter_flutter`, channel `ohos`) — required for `flutter build hap`. Stock Flutter has no OHOS engine.

The `.envrc` (managed by direnv) points `PATH` at the OHOS fork by default. Build scripts in `scripts/` enforce the correct SDK.

## Build Commands

```bash
# Day-to-day dev (uses whichever SDK is on PATH)
flutter pub get
flutter run              # run on connected device/emulator

# Linux release (forces upstream SDK)
scripts/build-linux.sh

# OHOS HAP release (forces OHOS fork)
scripts/build-ohos.sh           # default: hap
scripts/build-ohos.sh app       # or: app, har, hsp
```

OHOS signing material is injected from env vars (`OHOS_*`) via `ohos/scripts/generate-build-profile.mjs`. Copy `.envrc.example` and fill in your DevEco-encrypted passwords.

## Lint & Test

```bash
flutter analyze          # static analysis (flutter_lints)
flutter test             # run all tests
flutter test test/assignment_service_test.dart   # single test
```

## Architecture

### Service layer (`lib/services/`)

All services are created in `main.dart`, wired together manually (no DI framework), and provided to the widget tree via a single `ServiceProvider` (InheritedWidget). Access with `ServiceProvider.of(context)`.

Key services:
- **AuthService** — primary account ONLY: GeekPie Uni-Auth (Casdoor) SSO login via `UniAuthService`, SSO token refresh, logout cascade. Owns the SSO identity session (`UserSession` with `geekpieToken`/`geekpieRefreshToken`). It deliberately knows nothing about CASTGC/CpDaily — `UserSession` has no `tgc`/`cookies`/`sessionToken`/`tenantId` fields.
- **UniAuthService** — Casdoor OAuth: `login()`/`loginSdkOnly()` exchange an authorization code for an `SsoTokens` bundle (access + refresh + expiry); `refresh()` rotates them.
- **ScheduleService** — semester list, course table, term-begin date; CpDaily cookies from the eGate binding (`ThirdPartyAuthService.egateCookies()`); auto-retries with `renewEgateBinding()` on 401
- **AssignmentService** — aggregates deadlines from Blackboard + exam table (both via the eGate binding's CpDaily session), Gradescope, and Hydro (third-party tokens); merges per-platform results so a single platform failure doesn't wipe others
- **ThirdPartyAuthService** — bind/unbind/auto-renew for Gradescope, Hydro, **and eGate**. The eGate binding (`ThirdPartyPlatform.egate`) is the SINGLE source of CASTGC / CpDaily session in the app: `hasEgateBinding`, `egateBinding`, `egateCookies()` (always appends `CASTGC=<tgc>`), `egateStudentId`, `renewEgateBinding()` (renews via `/api/auth/renew` and persists back). Every campus-system feature (schedule, blackboard, exam, oa-gym, ecourse/student-leave webviews) reads its CpDaily session through these accessors, never from `AuthService.session`.
- **StorageService** — wraps `FlutterSecureStorage` (credentials) + `SharedPreferences` (caches, settings). **Important:** imports `flutter_secure_storage_ohos` (a hard fork), NOT the upstream `flutter_secure_storage` facade
- **ThemeService** — Material dynamic color, theme mode persistence

### Auth model boundary (important)

There are two distinct account tiers — do not cross them:
- **Primary account** = GeekPie SSO (Casdoor). Determines `auth.isLoggedIn` and user identity (userName). Produces NO CASTGC.
- **eGate binding** = a third-party account that holds the campus CpDaily session (CASTGC). Required by every campus-system feature. A user can be SSO-logged-in but have no eGate binding — such a user is "logged in" but cannot use schedule/blackboard/exam/gym/webview features until they bind eGate.

CASTGC must never be read off `AuthService.session`. Always go through `ThirdPartyAuthService.egateCookies()` / `egateStudentId` / `renewEgateBinding()`.

### Boot sequence (`main.dart`)

1. Synchronous: hydrate all caches from local storage (critical path — no network).
2. `runApp` immediately with cached data.
3. Unawaited background: renew tokens (main + third-party in parallel), then fan out schedule/assignment fetches.

### Navigation (`lib/widgets/app_shell/`)

Responsive shell: `DesktopShell` (sidebar, >=600px; collapsible >=960px) or `MobileShell` (bottom nav). Page transitions use `FadeThroughTransition`.

### Platform adaptation (`lib/utils/platform.dart`)

iOS Liquid Glass (iOS 26+) vs legacy iOS chrome is detected at boot via a MethodChannel (`techpie/platform`). Helper functions `isIos()`, `usesIosLiquidGlass()`, `usesLegacyIosChrome()` gate UI branches throughout the app.

### Features / WebView (`lib/models/feature.dart`)

Campus web services (ecourse, student leave, etc.) are opened in an in-app WebView with injected CASTGC cookies sourced from the eGate binding (`ThirdPartyAuthService.egateCookies()`). The `Feature` model declares `FeatureMode.native` vs `FeatureMode.webviewWithCookie`.

## Releasing

`pubspec.yaml` is the single version source: `version: X.Y.Z[-pre.N]+B`. Nothing
else declares a version — the OHOS `AppScope/app.json5` is generated from it at
build time, Android/iOS/Windows/Linux derive their stamps from it, and a release
tag must agree with it or the release workflow refuses to publish.

- **Changing the version on `master`** publishes a pre-release: `release.yml`
  plans it, tags `android-v<name>+B` / `ios-v<name>+B`, then calls the Android
  build and the iOS dispatch. The build number *is* the pre-release ordinal, so
  `1.0.0+4` releases as `1.0.0-rc.4` — one number pins everything, and nothing is
  inferred from tag history. A suffix written in pubspec is accepted only when it
  says exactly that (`1.0.0-rc.4+4`); anything else is refused. The suffix never
  reaches the platform version stamps, because iOS rejects a
  `CFBundleShortVersionString` like `1.0.0-rc.4`.
- **Cutting a `release/X.Y.Z` branch** publishes the stable release for `X.Y.Z`.
  The branch must carry exactly that version, with no pre-release suffix.
- `+B` must be above the released Android build (Play requires an increase) and
  above the released iOS build for the same version. Bump it for every release.
- Tags are created by CI. Do not tag a release by hand; a tag that disagrees
  with pubspec is refused. Nothing is tagged until the commit being released
  passes `flutter analyze` and `flutter test` inside the release run itself
  (`analyze.yml` passing on the same commit proves nothing — GitHub does not
  order workflow runs).
- The repository variable `RELEASE_FREEZE=true` merges a version change without
  publishing: the plan still lands in the run summary, tagging and every
  platform build are skipped.
- **OHOS**: each release also publishes an unsigned hap
  (`techpie-<version>-unsigned.hap` plus its sha256) attached to the GitHub
  release, built by `scripts/build-unsigned-hap.sh` with `OHOS_UNSIGNED=1` (the
  generator writes a profile without signing material, so hvigor packs the
  unsigned hap). Signing happens on the device owner's machine, never in CI.
  The job is off until a runner carrying the OHOS Flutter fork and the DevEco
  command-line tools exists: set the repository variables `OHOS_CI_ENABLED=true`
  and `OHOS_CI_RUNNER=<runner label>`.
  Note: `flutter build hap` reports "Hvigor build failed to produce an hap file"
  for such a build — it looks for the `-signed.hap` the signing config would
  have produced. The script judges the build by the artifact instead.
  Also note: the OHOS toolchain rewrites `AppScope/app.json5`'s version fields
  itself and hvigor flattens a pre-release name, so a declared `1.0.0-rc.4+5`
  packs as versionName `1.0.0.4` with versionCode 5. Android and iOS get the
  pre-release name stripped instead (iOS forbids it in
  `CFBundleShortVersionString`), which is why the release name lives in the tag.

## OHOS-Specific Gotchas

- Many upstream pub packages lack OHOS platform implementations. The `dependency_overrides` in `pubspec.yaml` point to OpenHarmony-SIG forks that add OHOS MethodChannel bindings. Don't remove these overrides without testing on OHOS.
- Dart/Flutter SDK is pinned to an older version for HarmonyOS compatibility (see README warning).
- `flutter_secure_storage_ohos` is NOT a federated plugin — it's a full fork with its own `FlutterSecureStorage` class. Importing the upstream package will crash on OHOS.

## API Pattern

All services talk to a Node.js backend. Pattern: POST JSON with auth tokens, check `{success: true}`, handle 401 with token renewal + retry. Base URL is toggled by a `useLocalhost` setting in `StorageService`.
