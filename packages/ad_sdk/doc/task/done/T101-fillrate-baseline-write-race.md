# T101 — FillRateBaselineMonitor ghi baseline không tuần tự, mất delta

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/monetization/fill_rate_baseline_monitor.dart`, `lib/src/utils/ad_preferences.dart`

## Vấn đề

`recordFillRateBaselineSample()` được gọi bằng `unawaited`. Mỗi lần ghi đọc toàn bộ JSON, cộng delta rồi ghi lại. Hai event load/revenue sát nhau có thể cùng đọc snapshot cũ, ghi hoàn tất sau cùng làm mất delta của ghi kia. Baseline 7 ngày (T97) vì vậy thấp/sai, kéo theo cảnh báo regression sai. [đồng thuận — codex+agy]

## Việc cần làm

- [x] Thêm write-chain theo instance (`AdPreferences._fillRateBaselineChain`, cùng idiom `AdEventLog._persistChain` đã có) — mỗi write chờ write trước xong mới bắt đầu đọc, không còn đọc-cùng-snapshot-cũ.
- [x] Test: seam `AdPreferences.debugFillRateWriteDelay` (test-only) tái hiện đúng độ trễ I/O thật — mock SharedPreferences trong test nhanh tới mức race không tự lộ nếu không có seam này. Revert→đỏ đúng chỗ (`Expected: <1> Actual: <null>`), fix lại→xanh. `test/fill_rate_baseline_monitor_test.dart`.
- [ ] "Chờ flush khi disable/destroy" — BỎ QUA có chủ đích: chain đã tự đảm bảo không mất delta bất kể `dispose()` gọi lúc nào (write pending vẫn chạy tới cùng độc lập với vòng đời object); flush-on-dispose chỉ có giá trị cho ca "process chết đúng lúc" — edge case rất hẹp, không đáng đổi API `dispose()` từ `void` sang `Future<void>` (dù về mặt Dart không phải breaking change, vẫn là thay đổi bề mặt API không cần thiết cho lợi ích nhỏ này).

## QA bổ sung (round-27 QA-hardening)

- [ ] KHÔNG thêm integration test riêng — `AdPreferences`/`_fillRateBaselineChain` là internal, không export public, không có điểm chạm qua `AdManager()` để black-box test từ example. Đã có unit test dùng `debugFillRateWriteDelay` chứng minh race đã đóng — coi là đủ cho 1 write-ordering bug nội bộ.

**Xác nhận chạy thật trên thiết bị (2026-09-01):** pass trên emulator Pixel_10_Pro_XL và máy thật Samsung SM-S928B, `--dart-define=AD_PROVIDER_ADMOB=true`. Không phải chỉ `flutter analyze`.
