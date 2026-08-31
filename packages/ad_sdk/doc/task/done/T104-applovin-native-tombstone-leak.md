# T104 — AppLovinAdapter._disposedNativeKeys phình vô hạn trong feed cuộn

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/adapters/applovin_adapter.dart:487-545`

## Vấn đề

`_disposedNativeKeys` là 1 `Set<Object>` tombstone — key thêm vào khi 1 native-ad instance dispose, chỉ gỡ qua `reviveNativeInstance(key)` (chỉ gọi khi đúng State widget mount lại chính instance cũ). Native ad trong `ListView`/feed cuộn qua khỏi màn hình và dispose vĩnh viễn (không bao giờ mount lại đúng key) sẽ không bao giờ revive — leak tuyến tính theo số native ad đã hiển thị trong phiên dài (feed vô hạn). `AdMobAdapter` không bị vì dùng `identical` trực tiếp trên slot thay vì tombstone Set.

## Việc cần làm

- [x] **KHÔNG đổi sang identity-comparison như AdMob** — đọc kỹ comment sẵn có (dòng ~470-478): `MaxNativeAdView`'s callback re-resolve `adapter.native(instanceKey)` MỖI LẦN gọi (không capture 1 lần như AdMob's `preloadNative`), nên trick "so identity slot đã capture" của AdMob không áp dụng thẳng được — cần đổi cả cách `native_ad_widget.dart` capture callback, rủi ro cao hơn hẳn dự kiến ban đầu của ticket (đã note lại trong DEBT-2/T115 cho ai muốn làm hướng lớn này sau).
- [x] Thay bằng: `LinkedHashSet` + cap cứng 200 key (`_maxDisposedNativeKeys`), tự evict key CŨ NHẤT khi vượt — chặn đứng "phình vô hạn" bằng 4 dòng, không đụng kiến trúc callback. Đánh đổi: 1 callback trễ hơn 200 lần dispose khác mới bị bỏ lọt (thực tế cực hiếm) — chấp nhận được, tombstone vốn chỉ để chặn callback "trễ", không phải "trễ vô hạn".
- [x] Test: `applovin_adapter_test.dart` — dispose 500 key khác nhau, xác nhận `debugDisposedNativeKeysCount <= 200`. Mutation-verified (revert → đỏ, fix lại → xanh).
