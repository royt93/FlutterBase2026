# T44 — ad_sdk example app hardcode App ID AdMob thật của production

- **REQ:** phát hiện qua audit sâu 2026-07-19 (agent "Audit ad_sdk example app for gaps")
- **Priority:** P3 (không phải secret, không gây mất tiền/crash — chỉ là vệ sinh code) · **Status:** ✅ done (2026-07-19)
- **Files:** `packages/ad_sdk/example/android/app/src/main/AndroidManifest.xml`, `packages/ad_sdk/example/ios/Runner/Info.plist`

## Vấn đề (Why)
`com.google.android.gms.ads.APPLICATION_ID` (Android) và `GADApplicationIdentifier` (iOS) trong example app hardcode `ca-app-pub-3004713799155145~9488250427` — **đây chính là App ID production thật của app FastNet** (đối chiếu `android/app/src/main/AndroidManifest.xml` của host app, cùng giá trị). Trong khi mọi ad unit ID dùng trong `example/lib/main.dart` đều là ID test công khai của Google. Không sai kỹ thuật, nhưng example app là nơi dev/test SDK, commit công khai trong repo — không nên gắn định danh tài khoản AdMob production thật vào đây, dễ gây nhầm lẫn khi đọc code.

## Giải pháp đã áp dụng
Thay bằng App ID test chính thức của Google:
- Android: `ca-app-pub-3940256099942544~3347511713`
- iOS: `ca-app-pub-3940256099942544~1458002511`

Thêm comment ngắn ghi rõ đây là test App ID cho dev/demo app, không phải production.

## Acceptance criteria
- [x] Android/iOS example app dùng App ID test của Google, không còn giá trị production thật.
- [x] `flutter analyze` (example) sạch — 0 issues.
- [x] Verify trên Pixel 7 Pro (2B051FDH3006MU): `flutter test integration_test/app_boot_test.dart` — 3/3 pass, log xác nhận `AppLovinAdapter initialize ✅ SDK ready` và AdManager healthy sau boot với App ID mới. (Full `vip_api_playground_test.dart` đã verify ổn định riêng trong phiên trước, không phụ thuộc App ID nên không cần chạy lại toàn bộ suite cho thay đổi cosmetic này.)
