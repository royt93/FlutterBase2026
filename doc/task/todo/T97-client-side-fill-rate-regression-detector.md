# T97 — Flagship: Client-side fill-rate/eCPM regression detector so baseline 7 ngày on-device

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng flagship, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `packages/ad_sdk/lib/src/debug/` (compliance/debug overlay)

## Vì sao độc quyền
So sánh fill-rate/eCPM phiên hiện tại với baseline 7 ngày lưu cục bộ trên chính thiết bị, tự động cảnh báo "fill rate ad unit X giảm Y% so với baseline của thiết bị này" ngay trong debug/compliance overlay — điều dashboard AppLovin/AdMob thật cần backend để làm, ở đây chạy per-device, không cần server. Nhất quán hướng thiết kế offline-first xuyên suốt SDK (VIP Ed25519 offline, safety layer client-side).

## Việc cần làm (đề xuất, chưa code)
- [ ] Lưu rolling 7-ngày fill-rate/eCPM per ad unit cục bộ.
- [ ] So sánh phiên hiện tại vs baseline, threshold cảnh báo cấu hình được.
- [ ] Hiển thị trong debug overlay (không cần thêm dependency backend).
