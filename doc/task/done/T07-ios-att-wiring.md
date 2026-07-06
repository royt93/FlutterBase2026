# T07 — Wiring iOS ATT đúng thứ tự + assert plist

- **REQ:** 6 (consent iOS)
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** done
- **Files:** `core/att_consent.dart`, `core/ad_manager.dart` (`requestAtt` `:953`), host splash, `ios/Runner/Info.plist`

## Vấn đề (Why)
`att_consent.dart` bản thân chuẩn (map status, xử lý zero-IDFA, degrade an toàn khi thiếu plugin/plist). Nhưng là opt-in; cần wiring **đúng thứ tự** (ATT **trước** UMP, sau first frame) và cần key `NSUserTrackingUsageDescription`. Thiếu key → prompt fail âm thầm, App Store có thể reject.

## Acceptance criteria
- [x] Splash gọi `requestAtt()` sau first frame, **trước** UMP form (T01/T03), rồi mới init/consent/ad.
- [x] Nếu thiếu `NSUserTrackingUsageDescription`: log ERROR (không chỉ warn) + assert debug để dev phát hiện sớm. (`att_consent.dart` — `assert()` wrapped `SafeLogger.e()` ngay trước `requestAuthorization()`, chỉ chạy ở debug build.)
- [x] Xác nhận `Info.plist` có `NSUserTrackingUsageDescription`, `GADApplicationIdentifier`, `SKAdNetworkItems`, `AppLovinSdkKey` (theo CLAUDE.md native gotchas).
- [x] Trên non-iOS: `requestAtt` no-op (`notSupported`) — không chặn flow.
- [x] README cập nhật thứ tự ATT → UMP → init.

## Test
- [x] Unit: dùng override params của `requestAttIfNeeded` để test notDetermined→authorized/denied (đã có sẵn, bao phủ đủ nhánh — assert-log không tạo nhánh quan sát được mới nên không cần test thêm).
