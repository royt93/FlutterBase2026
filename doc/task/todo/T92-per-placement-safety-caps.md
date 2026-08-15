# T92 — Ý tưởng: Per-placement safety cap (không chỉ global)

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/config/ad_safety_config.dart`

## Ý tưởng
Cap hiện tại (daily/hourly/session) áp dụng toàn cục theo loại ad, không phân biệt placement (vd splash vs sau khi hoàn thành 1 tác vụ trong app). Cho phép cap riêng theo placement giúp host tinh chỉnh UX chi tiết hơn mà không phải tắt cap toàn SDK.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thiết kế API cấu hình cap theo `placement` (string/key tự đặt) song song cap global hiện có.
