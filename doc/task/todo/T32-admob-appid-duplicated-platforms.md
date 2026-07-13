# T32 — AdMob Application ID giống hệt nhau giữa Android và iOS

- **REQ:** 1 (provider AdMob/AppLovin, Android + iOS)
- **Priority:** P1 · **Severity:** MEDIUM (thấp *hiện tại* vì AdMob đang dormant) · **Status:** 📋 todo (phát hiện mới 2026-07-13)
- **Files:** `android/app/src/main/AndroidManifest.xml` (`com.google.android.gms.ads.APPLICATION_ID`), `ios/Runner/Info.plist` (`GADApplicationIdentifier`)

## Vấn đề (Why)
Cả 2 file đang dùng **cùng 1 giá trị** `ca-app-pub-3612191981543807~9731053733`. AdMob console cấp App ID **riêng biệt** cho mỗi platform app entry (Android app và iOS app là 2 entry khác nhau trên console, dù cùng 1 project) — nhiều khả năng ID của iOS đang bị dán nhầm ID của Android (hoặc ngược lại). Rủi ro hiện tại thấp vì runtime provider đang cố định `AdProvider.appLovin` (AdMob dormant, dùng test-unit-id công khai của Google — an toàn vì không request thật), nhưng đây là bug native config thật, **bắt buộc phải sửa trước khi bao giờ flip provider sang AdMob**, nếu không app AdMob sẽ không init được đúng account trên 1 trong 2 platform.

## Giải pháp đề xuất
- Vào AdMob console, xác nhận App ID thật của app entry Android và app entry iOS (2 giá trị khác nhau).
- Cập nhật đúng giá trị vào từng file tương ứng.
- Grep lại toàn repo (kể cả `packages/ad_sdk/example/`) để chắc không còn chỗ nào khác bị copy nhầm cùng 1 giá trị.

## Acceptance criteria
- [ ] `AndroidManifest.xml` và `Info.plist` có 2 giá trị App ID **khác nhau**, khớp đúng console.
- [ ] Ghi chú lại trong `doc/feature.md` giá trị nào ứng với platform nào, tránh lặp lại nhầm lẫn.

## Test
Không cần unit test (native config, không phải Dart logic) — verify thủ công qua `MobileAds.instance.initialize()` log ở mỗi platform không báo lỗi "Invalid App ID" khi thử bật lại provider AdMob tạm thời để kiểm tra.
