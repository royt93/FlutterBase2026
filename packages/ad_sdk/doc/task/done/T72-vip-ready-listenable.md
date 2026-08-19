# T72 — Expose `ValueListenable` cho trạng thái `AdManager().vip` sẵn sàng

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:107,242`

## Vấn đề (Why)
`AdManager().vip` trả `null` cho tới khi `initialize()` xong. Nếu screen render trước khi SDK init xong, dev không có cách nghe thời điểm `vip` sẵn sàng ngoài tự poll `initRevision`.

## Đề xuất
Thêm `AdManager().vipReadyNotifier` (hoặc tương tự) — `ValueListenable<bool>` báo khi `vip` đã sẵn sàng, DX rõ ràng hơn polling thủ công.

## Acceptance criteria
- [x] `vipReadyNotifier` (hoặc tên tương đương) fire đúng 1 lần khi `vip` chuyển từ null → sẵn sàng.
- [x] README cập nhật ví dụ dùng.

## Đã làm (2026-08-16)
Thêm `AdManager().vipReady` — `ValueListenable<bool>` (`ValueNotifier<bool>` nội bộ, mặc định `false`). Set `true` ngay tại điểm `_vipManager = vip` trong `initialize()` (Phase 4), reset `false` trong `destroy()` (đối xứng với `_vipManager = null` ở đó). Không đụng `debugVipManager` setter (test seam thuần cho gating logic, không liên quan init flow thật — tránh coupling ngoài ý muốn).

README: thêm section "Waiting for VIP to be ready" với ví dụ `ValueListenableBuilder` lồng nhau (chờ `vipReady` rồi mới đọc `vip!.activeListenable`), đặt ngay trước "Check VIP state".

TDD: test mới trong `ad_manager_core_test.dart` gọi `AdManager().destroy()` để đảm bảo clean slate, assert `vip`/`vipReady.value` đều null/false, gọi `initialize()` thật (không mock adapter — Phase 4 chạy trước cả bước native adapter.initialize() nên không cần platform channel), assert listener chỉ fire đúng 1 lần với giá trị `true`.

`flutter test`: 733/733 pass (chạy 2 lần xác nhận ổn định), `flutter analyze` sạch.
