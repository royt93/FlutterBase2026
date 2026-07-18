# UMP / GDPR consent form setup (release blocker)

This is a **dashboard task** — no code change is needed. The SDK already calls
`AdManager().requestUmpConsent()` in the splash (before the first ad request),
but the consent **message has not been created** on the AdMob side, so the form
never appears. Device logs originally showed this against the old (wrongly
duplicated) production App ID:

```
[UmpConsent] ⚠️ requestConsentInfoUpdate failed: ... no form(s) configured for
the input app ID. Received app ID: ca-app-pub-3612191981543807~9731053733
```

**Since T32 (2026-07-14)** the app runs on Google's official **test** App IDs
(`~3347511713` Android / `~1458002511` iOS — see `doc/feature.md` T32) while the
real production App IDs (Android + iOS, separate per platform) are still
pending setup. The steps below still apply once against **your real production
App ID** — a UMP message configured against a test App ID is not meaningful
for a real release. Do this as part of the "go live" checklist in
`doc/feature.md` (§ "Checklist thao tác tay — trước khi release thật").

The SDK degrades gracefully (`canRequestAds=true`), but **EU/EEA/UK users never
see a consent form** → this must be fixed before an EEA release.

## What you need

- AdMob account that owns your real **production** App ID (Android + iOS,
  created after completing the T32 checklist — do NOT configure this against
  the test App ID above).
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
- Tracked as the release blocker in `doc/feature.md` and `doc/AD.MD`.
