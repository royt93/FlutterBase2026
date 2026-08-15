# T75 — Public `ValueListenable` cho fullscreen mutex busy state

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:644,2267,2458`

## Vấn đề (Why)
`_fullscreenBusyReason` bảo vệ tốt trong SDK nhưng app không quan sát được trạng thái busy để disable CTA hoặc tránh mở dialog riêng chồng lên.

## Đề xuất
Expose `ValueListenable<FullscreenBusyState>` hoặc stream read-only.

## Acceptance criteria
- [ ] Listenable phản ánh đúng thời điểm bắt đầu/kết thúc fullscreen busy trong test.
