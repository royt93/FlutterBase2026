# T104 — AppLovinAdapter._disposedNativeKeys phình vô hạn trong feed cuộn

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/adapters/applovin_adapter.dart:487-545`

## Vấn đề

`_disposedNativeKeys` là 1 `Set<Object>` tombstone — key thêm vào khi 1 native-ad instance dispose, chỉ gỡ qua `reviveNativeInstance(key)` (chỉ gọi khi đúng State widget mount lại chính instance cũ). Native ad trong `ListView`/feed cuộn qua khỏi màn hình và dispose vĩnh viễn (không bao giờ mount lại đúng key) sẽ không bao giờ revive — leak tuyến tính theo số native ad đã hiển thị trong phiên dài (feed vô hạn). `AdMobAdapter` không bị vì dùng `identical` trực tiếp trên slot thay vì tombstone Set.

## Việc cần làm

- [ ] Thay Set không giới hạn bằng cơ chế tự dọn theo TTL, HOẶC bỏ model tombstone-Set để đổi sang so sánh identity giống AdMob adapter (root-cause fix, nhất quán 2 adapter — ưu tiên hướng này, xem DEBT-2/T115)
- [ ] Test: N native ad dispose liên tiếp không revive, xác nhận `_disposedNativeKeys` không tăng vô hạn (TTL) hoặc không tồn tại (nếu đổi model)
