# T124 — Idea: AdaptiveAdSurface — 1 widget tự chọn banner/MREC/native theo kích thước

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (batch D, 2026-08-31 — scope: banner/MREC 2-way, không native, xem "Đã làm")
- **Files:** 3 widget inline hiện có, 2 adapter/bridge, `MediaQuery`, visibility helper

## Vấn đề

AppLovin đã thích ứng width và AdMob có anchored adaptive sizing, nhưng host vẫn tự quyết banner/MREC/native và breakpoint. [đồng thuận 3 nguồn]

## Việc cần làm

- [x] `AdaptiveAdSurface` tự chọn banner/MREC theo available width — KHÔNG bao gồm native-template (xem "Đã làm"); "policy host" = `mrecBreakpoint` truyền vào constructor
- [x] Debounce resize (mặc định 200ms, first-layout luôn commit ngay không debounce), giữ đúng instance ownership (Key riêng theo format → Flutter tự dispose widget cũ khi switch)
- [x] Không đổi format khi fullscreen đang bận — dùng `AdSdkStateSnapshot.fullscreenBusy` (T109)
- [x] Test: `test/adaptive_ad_surface_test.dart` (6 test) — chọn đúng format theo width/breakpoint tuỳ chỉnh, debounce đúng (chưa switch trong cửa sổ, huỷ nếu revert trước khi debounce bắn), unmount giữa lúc debounce không throw

## Đã làm (batch D, 2026-08-31)

`lib/src/widget/adaptive_ad_surface.dart`. **Không làm native** — khác banner/
MREC, nội dung native template do host tự soạn (headline/CTA/hình ảnh), tự
động chuyển sang native chỉ dựa trên width cần 1 hợp đồng nội dung widget
này chưa có — để dành follow-up thay vì đoán. Orientation không có tham số
riêng — width đã tự phản ánh xoay màn hình (xoay ngang = width tăng, giống
hiệu ứng tablet), thêm tham số riêng cho orientation là dư thừa cho v1.
