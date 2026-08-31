# T105 — Thiếu guard identical() trên onAdOpened/onAdClicked + eventSink không null hoá (AppLovin dispose)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/adapters/admob_adapter.dart` (quanh `onAdOpened`/`onAdClicked` banner/mrec/native), `lib/src/adapters/applovin_adapter.dart:159,164`

## Vấn đề

Round-26 finding #2 (còn mở) chỉ nêu AdMob's `onFailed` thiếu `_discardIfDisposed` đối xứng với `onLoaded`. `onAdOpened`/`onAdClicked` (banner/mrec/native) cũng thiếu guard `identical(_xSlotsByKey[key], slot)` mà `onAdLoaded`/`onAdFailedToLoad` đã có. `eventSink` (AppLovin) không được set `null` trong `dispose()` — cùng lỗ hổng phía AppLovin mà round-26 #2 chỉ note phía AdMob. Click/open event tới TRỄ (sau dispose) vẫn ghi vào CTR-fraud counter và emit `AdClickEvent` cho placement không còn tồn tại — nhiễu số liệu nuôi chính tầng anti-fraud.

## Việc cần làm

- [ ] Nhân bản guard `identical(...)` đã áp dụng cho `onAdLoaded` sang `onAdOpened`/`onAdClicked` (cả 2 adapter, cả banner/mrec/native)
- [ ] Null hoá `eventSink` trong `dispose()` của AppLovin adapter
- [ ] Fix chung 1 chỗ (cùng root cause với round-26 #2, không tách PR riêng)
- [ ] Test: click/open event tới sau dispose, xác nhận không ghi vào CTR counter / không emit event
