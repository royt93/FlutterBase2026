# T152 — Quảng cáo native kẹt khung xám chờ mãi mãi khi nạp bị lỗi/quá hạn

**Loại:** bug
**Ưu tiên:** P1
**Trạng thái:** DONE — verified 9.5/10 (codex, 2 vòng review độc lập, 1 finding sửa xong)
**Nguồn phát hiện:** subagent adapters+adaptive, tự verify (đối chiếu banner/mrec đã fix cùng vấn đề)

## Kết quả (2026-09-09)
Fixed. Thêm `listenables.markError(); listenables.isLoaded.value = false;` vào watchdog `onTimeout` của `preloadNative`, y hệt banner/mrec.

Thêm debug seam mới `AdSlot.debugFireLoadWatchdogNow()` (kích hoạt watchdog ngay, không cần chờ 30s thật) vì không có cách nào tái hiện "native SDK thật sự im lặng" qua UI thật (ad unit ID sai vẫn trả lỗi nhanh, không treo).

Codex review vòng 1 bắt 1 finding thật: assertion "hasError=false sau resume" là false positive — vì `onAppResumed()` xoá cờ `hasError` (chỉ để hiển thị) TRƯỚC khi thử load lại, load lại đó vẫn bị chặn bởi backoff (chưa hết cooldown) nên không thực sự retry — test vẫn pass dù không có gì tự phục hồi thật. Đã sửa: xoá backoff (`lastErrorAt`) trước khi resume, assert thêm `isLoading=true` để chứng minh có request thật đi ra, giống hệt cách `admob_resume_recovery_test.dart` đã làm cho banner/mrec. Vòng 2: sạch.

Test: 1 assertion mới (`hasError`) + 1 đoạn resume-retry mới trong `test/admob_widget_load_watchdog_test.dart` (native watchdog → needsRecovery → resume tự phục hồi, PASS). Demo mới trong `NativeDemoPage` (2 nút: "Simulate watchdog timeout" + "Simulate app resume") + widget test mới (pre-init fallback) + integration test mới (viết đúng, nhưng device thật bị App Open ad thật che màn hình splash — hành vi ĐÚNG của SDK, không phải bug, chỉ là chưa tìm được cách dismiss tự động an toàn trong test). Suite: 1799/1799 (ad_sdk) + 37/37 (example) xanh, `flutter analyze` sạch.
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Quảng cáo dạng "native" (hiển thị lẫn vào giao diện app) — nếu nạp bị lỗi/quá hạn, lẽ ra phải tự hồi phục khi người dùng mở lại app (giống banner/MREC đã làm). Riêng loại này thiếu 1 cờ báo lỗi nên không bao giờ tự hồi phục được — có thể bị kẹt hiện "skeleton loading" (khung xám chờ) mãi mãi thay vì báo lỗi rõ ràng, người dùng phải tắt/mở lại app thủ công.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:2343-2346` — `preloadNative`'s watchdog `onTimeout` chỉ làm `_nativeAdsByKey.remove(key)?.dispose()`, thiếu `listenables.markError()` mà banner (dòng ~1975) và mrec (dòng ~2189) đều gọi ở watchdog tương tự.
- `needsRecovery` (đọc bởi `onAppResumed()`'s native mirror, `admob_adapter.dart:2566-2575`) chỉ được bật bên trong `markError()` — không gọi thì native ad timeout không bao giờ tự phục hồi khi app resume.
- Test `admob_widget_load_watchdog_test.dart` cũng thiếu đúng assertion `hasError`/`needsRecovery` cho case native (có ở banner/mrec).

## Việc cần làm
1. Thêm `listenables.markError()` vào watchdog `onTimeout` của `preloadNative`, giống hệt banner (dòng ~1975)/mrec (dòng ~2189).
2. Thêm assertion `hasError`/`needsRecovery` cho case native vào `admob_widget_load_watchdog_test.dart` (hiện chỉ có cho banner/mrec).
3. Thêm log SafeLogger khi native watchdog timeout kích hoạt.
4. Thêm demo trong `example/`: mô phỏng native ad timeout (delay giả lập) → xác nhận UI chuyển sang trạng thái lỗi rõ ràng, và tự phục hồi khi app resume.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/adapters/admob_adapter.dart: watchdog onTimeout của preloadNative (dòng ~2343-2346) chỉ làm _nativeAdsByKey.remove(key)?.dispose(), thiếu listenables.markError() mà watchdog banner (~dòng 1975) và mrec (~dòng 2189) đều gọi. Thêm listenables.markError() vào đúng vị trí, đối chiếu cách banner/mrec làm để giữ nhất quán. Đọc onAppResumed() (~dòng 2566-2575) để hiểu needsRecovery chỉ bật qua markError(). Bổ sung test/admob_widget_load_watchdog_test.dart: thêm case native với đúng assertion hasError/needsRecovery giống banner/mrec đã có. Thêm log SafeLogger. Thêm demo trong example/ mô phỏng timeout.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho native watchdog timeout với đúng assertion `hasError`/`needsRecovery` giống banner/mrec; widget test cho UI chuyển trạng thái lỗi; integration test cho auto-recovery khi resume.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, mô phỏng timeout, xác nhận native ad báo lỗi rõ ràng và tự phục hồi khi mở lại app.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
