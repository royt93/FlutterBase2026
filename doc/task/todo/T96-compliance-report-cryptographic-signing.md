# T96 — Flagship: Compliance report ký số (cryptographically signed export) — nâng cấp tính năng đã có

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** 🔲 todo (nâng cấp tính năng có sẵn, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/compliance/compliance_report.dart`, `packages/ad_sdk/lib/src/compliance/ad_event_log.dart`

## Vì sao độc quyền
Raw AppLovin MAX/Google Mobile Ads/wrapper khác chỉ cho load/show callback. Package này ĐÃ CÓ event log + compliance report + debug overlay + policy risk score — khi tài khoản bị AdMob/AppLovin gắn cờ traffic bất thường, dev thường không có bằng chứng chi tiết để kháng cáo.

## Ý tưởng
Nâng compliance report hiện có thành bản ký số (Ed25519, tái dùng hạ tầng VIP key) — chứng minh log không bị chỉnh sửa sau khi xuất, tăng độ tin cậy khi dùng làm bằng chứng kháng cáo với ad network.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thêm chữ ký vào file export hiện có của `exportComplianceReport`.
- [ ] Tool verify độc lập (có thể CLI nhỏ) xác nhận chữ ký hợp lệ.
