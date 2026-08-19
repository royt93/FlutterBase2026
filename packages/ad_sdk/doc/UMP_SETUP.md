# UMP / GDPR consent form setup

**Status (2026-08-09): verified end-to-end.** Owner published the GDPR message
against the Android production App ID
(`ca-app-pub-3004713799155145~9488250427`), and the "How to verify it works"
debug check below was run on a real device (Pixel 7 Pro) the same day: forced
EEA debug geography rendered the consent form correctly, log confirmed
`status=required, formShown=true`. The temporary test code has been reverted;
splash runs `requestUmpConsent(testMode: false)` in production. **No longer a
release blocker for Android.** iOS is still pending its own AdMob app entry
(see `doc/AD_PROMPT_FLUTTER.MD` Phụ lục C) — redo this whole doc (including
the verify step) for iOS once that entry exists.

This is a **dashboard task** — no code change is needed. The SDK already calls
`AdManager().requestUmpConsent()` in the splash (before the first ad request),
but the consent **message has not been created** on the AdMob side, so the form
never appears. Device logs originally showed this against the first (wrongly
duplicated) production App ID:

```
[UmpConsent] ⚠️ requestConsentInfoUpdate failed: ... no form(s) configured for
the input app ID. Received app ID: ca-app-pub-3612191981543807~9731053733
```

**Correction (2026-08-09) — this doc was stale.** T32 (2026-07-14) had switched
the app to Google's test App IDs as a stopgap. Commit `ea54d16` (2026-07-18)
reverted that: `android/app/src/main/AndroidManifest.xml`,
`ios/Runner/Info.plist`, and `lib/mckimquyen/common/const/ad_keys.dart` now all
ship **`ca-app-pub-3004713799155145~9488250427`**.

**Current priority is Android only** (confirmed 2026-08-09) — this App ID is
the real production Android app entry, and its 4 ad unit IDs in `ad_keys.dart`
are real. iOS is intentionally deferred: it reuses the Android App ID/ad unit
IDs as a placeholder for now and will get its own real AdMob app
entry + ad units when iOS work is prioritized — not a bug to fix today.

The GDPR message publish above has been verified end-to-end on a real device
(see "How to verify it works") — forced EEA debug geography rendered the
consent form correctly and logged `status=required, formShown=true`. This
section is left below as history of how the gap was originally found; it no
longer describes the current state.

## What you need

- AdMob console access (Android app entry — `ca-app-pub-3004713799155145~9488250427`).
- The app's Privacy Policy URL (already wired in the app:
  `https://loitp.notion.site/Term-Privacy-Policy-...`).

## Steps (AdMob dashboard)

1. Go to **https://apps.admob.com** → **Privacy & messaging** (left sidebar).
2. Open the **GDPR** tab (the EEA + UK consent message).
3. Click **Create message** (or edit the existing one).
4. **Select the app**: pick your real production app entry (per-platform App
   ID, not the test ID). If your app isn't listed, add it under *Apps* first.
5. Configure the message:
   - **User consent options**: "Consent" + "Manage options" (so users can accept
     or reject — required for valid TCF consent).
   - **Privacy policy URL**: paste the app's policy URL.
   - Choose the ad partners / commercial purposes as needed.
6. Click **Publish**. (Saving a draft is NOT enough — it must be **published**.)
7. *(Optional but recommended)* On the **CCPA / US states** tab, publish a
   message too if you ship to California.

> Note: AppLovin MAX (the current runtime provider) uses Google UMP as its CMP,
> so this same GDPR message satisfies both AppLovin and AdMob.

## How to verify it works

After publishing, test with an EEA geography forced on a **debug** build. In the
splash, temporarily call:

```dart
await AdManager().requestUmpConsent(
  testMode: true,
  debugGeography: DebugGeography.debugGeographyEea,
  testIdentifiers: ['<your-device-hash-from-the-log>'],
);
```

Expected device log: `UMP done: ... status=required, formShown=true` and the
consent dialog appears. Once confirmed, revert the temporary `testMode` change
(production uses `requestUmpConsent(testMode: false)` so real geography decides).

## Where this is referenced

- Splash call site: `lib/mckimquyen/widget/splash/splash_screen.dart` (the
  `requestUmpConsent(testMode: false)` block).
- Was tracked as a release blocker in `doc/feature.md` and `doc/AD.MD`; cleared
  for Android per the verified status above.
