# T37 — `packages/ad_sdk/example/ios/Podfile`: iOS 13.0 pin bị comment out

- **REQ:** 1 (provider parity Android/iOS) — native config
- **Priority:** P2 · **Severity:** LOW · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/example/ios/Podfile`

## Vấn đề (Why)
Root app (`ios/Podfile:2`) có `platform :ios, '13.0'` đang active. Example app cùng dòng này đang bị **comment out** — lệch cấu hình, có thể khiến `pod install` của example app dùng deployment target mặc định khác (thường là target thấp hơn CocoaPods mặc định) thay vì 13.0 như đã cam kết ở README/CLAUDE.md ("Podfile targets iOS 13.0").

## Giải pháp đề xuất
Uncomment dòng `platform :ios, '13.0'` trong `packages/ad_sdk/example/ios/Podfile` cho khớp root app.

## Acceptance criteria
- [x] `example/ios/Podfile` có `platform :ios, '13.0'` active.
- [x] `pod install` lại example app không lỗi, build sim/device thành công.

## Test
Không cần unit test — verify bằng build thử example app trên iOS simulator sau khi sửa.

## Kết quả
Uncomment `platform :ios, '13.0'` tại `example/ios/Podfile:2`. `pod install` chạy sạch. Build + launch Debug trên iOS Simulator (iPhone 17 Pro Max, iOS 26.5) thành công, dùng luôn cho verify T38.

## Giới hạn đã biết
Không có, đây là fix cấu hình đơn giản khớp lại với root app Podfile.
