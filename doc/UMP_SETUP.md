# UMP / GDPR consent form setup (release blocker)

This is a **dashboard task** — no code change is needed. The SDK already calls
`AdManager().requestUmpConsent()` in the splash (before the first ad request),
but the consent **message has not been created** on the AdMob side, so the form
never appears. Device logs show:

```
[UmpConsent] ⚠️ requestConsentInfoUpdate failed: ... no form(s) configured for
the input app ID. Received app ID: ca-app-pub-3612191981543807~9731053733
```

The SDK degrades gracefully (`canRequestAds=true`), but **EU/EEA/UK users never
see a consent form** → this must be fixed before an EEA release.

## What you need

- AdMob account that owns app ID **`ca-app-pub-3612191981543807~9731053733`**.
- The app's Privacy Policy URL (already wired in the app:
  `https://loitp.notion.site/Term-Privacy-Policy-...`).

## Steps (AdMob dashboard)

1. Go to **https://apps.admob.com** → **Privacy & messaging** (left sidebar).
2. Open the **GDPR** tab (the EEA + UK consent message).
3. Click **Create message** (or edit the existing one).
4. **Select the app**: pick the app with ID
   `ca-app-pub-3612191981543807~9731053733`. (If your app isn't listed, add it
   under *Apps* first.)
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
