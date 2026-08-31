# T105 — Thiếu guard identical() trên onAdOpened/onAdClicked + eventSink không null hoá (AppLovin dispose)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/adapters/admob_adapter.dart` (quanh `onAdOpened`/`onAdClicked` banner/mrec/native), `lib/src/adapters/applovin_adapter.dart:159,164`

## Vấn đề

Round-26 finding #2 (còn mở) chỉ nêu AdMob's `onFailed` thiếu `_discardIfDisposed` đối xứng với `onLoaded`. `onAdOpened`/`onAdClicked` (banner/mrec/native) cũng thiếu guard `identical(_xSlotsByKey[key], slot)` mà `onAdLoaded`/`onAdFailedToLoad` đã có. `eventSink` (AppLovin) không được set `null` trong `dispose()` — cùng lỗ hổng phía AppLovin mà round-26 #2 chỉ note phía AdMob. Click/open event tới TRỄ (sau dispose) vẫn ghi vào CTR-fraud counter và emit `AdClickEvent` cho placement không còn tồn tại — nhiễu số liệu nuôi chính tầng anti-fraud.

## Việc cần làm

- [x] Nhân bản guard `identical(...)` đã áp dụng cho `onAdLoaded` sang `onAdOpened`/`onAdClicked` — cả 3 site AdMob (banner/mrec `onAdOpened`, native `onAdClicked`); AppLovin không cần vì route qua 1 listener chung đã bị null hoá ở `dispose()` (khác kiến trúc AdMob per-callback).
- [x] Null hoá `eventSink` trong `dispose()` của AppLovin adapter — ngay sau khối null-hoá listener, chặn 1 callback lỡ đã nằm trong hàng đợi Dart trước khi listener bị null.
- [x] Fix chung 1 chỗ, cùng root cause round-26 #2, cùng 1 ticket.
- [x] Test: `test/admob_late_callback_test.dart` (3 test mới: banner/mrec `onAdOpened`, native `onAdClicked` — dùng đúng listener thật qua debug seam sẵn có, xác nhận `events` rỗng sau khi callback tới trễ) + `test/applovin_adapter_test.dart` (1 test: `dispose()` phải null hoá `eventSink`). Mutation-verified cả 2 (revert → đỏ, fix lại → xanh).
