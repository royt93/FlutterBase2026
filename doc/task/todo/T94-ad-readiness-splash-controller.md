# T94 — Ý tưởng: `AdReadinessSplashController`/widget orchestration splash chính thức

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/README.md:73,139`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1061`

## Ý tưởng
README yêu cầu app tự set navigator key, route observer, ATT, UMP, init SDK, app-open/splash flow đúng thứ tự — nhiều bước dễ làm sai thứ tự. Một controller/widget first-party official hoá flow này sẽ giảm lỗi integration, giúp app mới có flow production-ready nhanh hơn.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thiết kế widget/controller gói gọn thứ tự bước README yêu cầu, vẫn cho phép app tuỳ biến UI splash riêng.
