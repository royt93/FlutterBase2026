# T149 — Nhánh kiểm tra lại form đồng ý bỏ dở thiếu lưới an toàn chống crash

**Loại:** bug
**Ưu tiên:** P1
**Trạng thái:** DONE — verified 9.5/10 (codex, 1 vòng review độc lập, sạch ngay)
**Nguồn phát hiện:** subagent core+state, tự verify trực tiếp code (đối chiếu round-39 MAJOR #3)

## Kết quả (2026-09-09)
Fixed. Bọc `runZonedGuarded` quanh `unawaited(_recheckAbandonedUmpForm())` ở cả 2 vị trí (`_scheduleNextRetry`'s periodic backstop, `_onConnectivityChanged`'s reconnect), y hệt cách nhánh `else` (`_retryUmpConsent()`) đã được vá ở round-39.

Thêm 2 test seam mới cần thiết để test được: `debugUmpFormAbandoned` (setter, trước chỉ có getter), `debugLastUmpResult` (force `_umpAnswered` về false — phát hiện lúc viết integration test on-device, vì flow init thật đã tự resolve UMP thành công khiến `_umpAnswered` luôn true, che mất nhánh cần test). Cũng thêm hook đọc `debugForceAutoUmpError` vào `_recheckAbandonedUmpForm()` (trước chỉ `_retryUmpConsent()` có).

Test: 2 unit test mới (`test/ump_abandoned_form_zone_guard_test.dart`, mirror round-39's `ump_retry_zone_guard_test.dart`) — cả 2 nhánh reconnect + backstop, PASS. Integration test mới on-device (`example/integration_test/ump_abandoned_form_crash_guard_test.dart`) — **PASS thật trên Pixel 7 Pro Android 17**, log xác nhận đúng dòng `"UMP reconnect abandoned-form recheck threw unhandled"` chạy mà app không crash (2 lần thử đầu bị VIP grace/UMP-đã-answered che mất nhánh — đã sửa bằng revokeAll() + debugLastUmpResult trước khi trigger). Suite: 1795/1795 (ad_sdk) + 33/33 (example) xanh, `flutter analyze` sạch.
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Khi mạng chập chờn giữa lúc form xin phép quảng cáo (theo luật châu Âu) bị người dùng bỏ dở, có 1 đoạn code không được "lưới an toàn" bảo vệ như các đoạn tương tự khác trong cùng file (những đoạn đó đã bị sửa lỗi crash y hệt hồi round 39). Hậu quả: có khả năng app bị crash lặp lại đúng kịch bản đã từng xảy ra, chỉ khác đúng 1 nhánh chưa được vá.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_manager.dart:~8086` và `~8222` (trong `_scheduleNextRetry`/`_onConnectivityChanged`): nhánh `if (_umpFormAbandoned) unawaited(_recheckAbandonedUmpForm())` KHÔNG được bọc `runZonedGuarded`, trong khi nhánh `else` liền kề (`_retryUmpConsent()`) đã được bọc ở cả 2 vị trí (round-39 fix MAJOR #3).
- `_recheckAbandonedUmpForm()` await cùng dạng API kênh gốc gây lỗi round-39 (`ConsentInformation.instance.canRequestAds()/getConsentStatus()`, `ump_consent.dart:350-351`).

## Việc cần làm
1. Bọc `unawaited(_recheckAbandonedUmpForm())` bằng `runZonedGuarded` giống hệt cách `_retryUmpConsent()` đã được bọc ở round-39, tại cả 2 vị trí gọi.
2. Thêm log SafeLogger khi bắt được lỗi trong zone này (để phân biệt với crash thật).
3. Thêm test mô phỏng: form UMP bị bỏ dở + kênh UMP native throw lỗi ngay lúc mạng đổi trạng thái — xác nhận không crash.
4. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_manager.dart: nhánh "if (_umpFormAbandoned) unawaited(_recheckAbandonedUmpForm())" ở cả 2 vị trí (~dòng 8086 trong _scheduleNextRetry, ~dòng 8222 trong _onConnectivityChanged) chưa được bọc runZonedGuarded, trong khi nhánh else liền kề (_retryUmpConsent()) đã được bọc đúng ở round-39 (MAJOR #3, xem doc/audit cho chi tiết cơ chế). Bọc runZonedGuarded y hệt cách round-39 đã làm cho cả 2 vị trí. Viết test mô phỏng ConsentInformation.instance.canRequestAds()/getConsentStatus() (ump_consent.dart:350-351) throw exception đúng lúc _umpFormAbandoned=true và mạng đổi trạng thái — xác nhận app không crash, lỗi được log qua SafeLogger.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit/integration test mô phỏng throw ở đúng nhánh `_recheckAbandonedUmpForm`, xác nhận không crash, có log ghi lại.
3. Log SafeLogger đầy đủ.
4. CHANGELOG.md cập nhật (không cần demo UI riêng vì đây là lưới an toàn nội bộ, nhưng nếu có debug overlay hiển thị trạng thái UMP thì thêm dòng trạng thái "form abandoned - rechecking" vào đó).
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device/simulator có bật EEA debug geography, bỏ dở form UMP rồi tắt/bật mạng liên tục, xác nhận không crash.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
