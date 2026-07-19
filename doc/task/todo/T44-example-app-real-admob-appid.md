# T44 — ad_sdk example app hardcode App ID AdMob thật của production

- **REQ:** phát hiện qua audit sâu 2026-07-19 (agent "Audit ad_sdk example app for gaps")
- **Priority:** P3 (không phải secret, không gây mất tiền/crash — chỉ là vệ sinh code) · **Status:** todo
- **Files:** `packages/ad_sdk/example/android/app/src/main/AndroidManifest.xml:41`, `packages/ad_sdk/example/ios/Runner/Info.plist:49`

## Vấn đề (Why)
`com.google.android.gms.ads.APPLICATION_ID` (Android) và `GADApplicationIdentifier` (iOS) trong example app đang hardcode `ca-app-pub-3004713799155145~9488250427` — **đây chính là App ID production thật của app FastNet** (đối chiếu `android/app/src/main/AndroidManifest.xml` của host app, cùng giá trị). Trong khi đó mọi ad unit ID dùng trong `example/lib/main.dart` đều là ID test công khai của Google (`ca-app-pub-3940256099942544/...`). Việc App ID thật + ad unit test không sai kỹ thuật (Google cho phép), nhưng:
- Example app là nơi dev/test SDK, commit công khai trong repo — không nên gắn định danh tài khoản AdMob production thật vào đây.
- Dễ gây nhầm lẫn khi đọc code (tưởng example đang chạy production thật).

## Đề xuất
Thay bằng App ID test chính thức của Google: `ca-app-pub-3940256099942544~3347511713` (Android) / `ca-app-pub-3940256099942544~1458002511` (iOS) — 2 giá trị test App ID công khai Google công bố, khớp với ad unit test đang dùng.

## Acceptance criteria
- [ ] Android/iOS example app dùng App ID test của Google, không còn giá trị production thật.
- [ ] `flutter test integration_test/` trong `packages/ad_sdk/example` vẫn pass sau khi đổi (App ID không ảnh hưởng logic test).
