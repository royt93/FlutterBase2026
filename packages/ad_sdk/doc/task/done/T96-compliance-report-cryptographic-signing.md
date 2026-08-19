# T96 — Flagship: Compliance report ký số (cryptographically signed export) — nâng cấp tính năng đã có

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** 🔲 todo (nâng cấp tính năng có sẵn, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/compliance/compliance_report.dart`, `packages/ad_sdk/lib/src/compliance/ad_event_log.dart`

## Vì sao độc quyền
Raw AppLovin MAX/Google Mobile Ads/wrapper khác chỉ cho load/show callback. Package này ĐÃ CÓ event log + compliance report + debug overlay + policy risk score — khi tài khoản bị AdMob/AppLovin gắn cờ traffic bất thường, dev thường không có bằng chứng chi tiết để kháng cáo.

## Ý tưởng
Nâng compliance report hiện có thành bản ký số (Ed25519, tái dùng hạ tầng VIP key) — chứng minh log không bị chỉnh sửa sau khi xuất, tăng độ tin cậy khi dùng làm bằng chứng kháng cáo với ad network.

## Việc cần làm (đề xuất, chưa code)
- [x] Thêm chữ ký vào file export hiện có của `exportComplianceReport`.
- [x] Tool verify độc lập (có thể CLI nhỏ) xác nhận chữ ký hợp lệ.

## Đã làm (2026-08-16)

Quyết định thiết kế quan trọng khác VIP key: VIP key ký OFFLINE (private key
không bao giờ lên máy), còn compliance report phải ký NGAY TRÊN THIẾT BỊ lúc
export (không có bên thứ ba offline nào để ký hộ) → threat model khác hẳn:
đây là tamper-evidence "file không bị sửa SAU KHI xuất", KHÔNG PHẢI
non-repudiation (chủ thiết bị luôn có quyền truy cập signing key, nên không
chứng minh được log gốc không bị ai đó có quyền admin thiết bị giả mạo từ đầu).
Đã ghi rõ giới hạn này trong doc comment `SignedComplianceReport` và README —
tránh dev hiểu nhầm đây là bằng chứng pháp lý tuyệt đối.

- `lib/src/compliance/compliance_signing.dart` (mới):
  - `SignedComplianceReport` — bundle gồm `reportJson` (chuỗi JSON CHÍNH XÁC
    đã ký, không phải object parse lại — tránh rủi ro re-serialize lệch byte),
    `publicKeyBase64`, `signatureBase64`.
  - `signComplianceReport(report, {secureStorage})` — mint (lần đầu) hoặc load
    lại Ed25519 key pair từ `flutter_secure_storage`, ký `utf8.encode(report.toJsonString())`.
  - `verifySignedComplianceReportJson(bundleJson)` — verify, không bao giờ
    throw (input hỏng → `false`).
- `lib/src/core/ad_manager.dart` — `exportSignedComplianceReport({from, to})`
  = `signComplianceReport(exportComplianceReport(from: from, to: to))`.
- `tool/verify_compliance_report.dart` (mới) — CLI:
  `dart run tool/verify_compliance_report.dart <path>` → in `VALID`/`INVALID`,
  exit code 0/1. Tự chứa (không import code Flutter-dependent của SDK) để
  chạy được bằng `dart run` thuần, giống convention `vip_mint.dart`.
- `lib/applovin_admob_sdk.dart` — export `compliance_signing.dart`.
- Scope quyết định KHÔNG làm (tự quyết): không tái dùng VIP Ed25519
  infrastructure/key như ý tưởng gốc đề xuất — VIP key là OFFLINE-signing
  (private key không bao giờ lên máy), còn compliance signing cần ký
  ON-DEVICE mỗi lần export, nên bắt buộc phải là key pair RIÊNG được sinh và
  lưu trên máy (không thể dùng chung VIP's public-key-only model). Đã ghi rõ
  lý do trong doc comment.
- Test mới: `test/compliance_signing_test.dart` (7 test) — ký rồi verify pass,
  `reportJson` round-trip đúng byte với `ComplianceReport.toJsonString()`, key
  ổn định qua nhiều lần ký cùng storage (giả lập cùng thiết bị), storage khác
  → key khác (giả lập thiết bị/install khác), sửa `reportJson` sau khi xuất →
  verify fail, hoán key công khai → verify fail, bundle hỏng/garbage → verify
  trả `false` chứ không throw.
- `flutter analyze`: No issues found! `flutter test`: 817/817 pass.
