# T128 — Flagship: Proof-of-compliance — audit trail ký số cho mọi lần bypass safety

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/compliance/bypass_audit_trail.dart` (mới), `lib/src/core/ad_manager.dart` (`bypassAuditTrail`, `callSiteTag` param trên `showAppOpenAd`/`showRewardedAd`), `tool/bypass_audit_replay.dart` (mới), `test/bypass_audit_trail_test.dart`

## Vấn đề

SDK đã có hạ tầng Ed25519 dùng cho VIP key (T18/AVP2), VIP revocation (T95), compliance report (T96) — nhưng chính các "cửa hậu" hợp pháp (`bypassSafety: true`, `bypassVipGuard: true`, `dryRun`) hiện chỉ là boolean trần, không kiểm chứng được SAU KHI build đã ship rằng chúng chỉ được gọi đúng nơi SDK cho phép (splash app-open, VIP-extend rewarded) chứ không bị lạm dụng để cày impression. [đồng thuận 3 nguồn]

## Việc cần làm

- [x] Mỗi lần `bypassSafety`/`bypassVipGuard` được gọi (== true): ghi 1 `BypassAuditEntry` (timestampMs, kind, callSiteTag do host truyền vào tham số mới, type) vào ring buffer `AdManager().bypassAuditTrail` (luôn bật, cap 200 entry, KHÔNG reset qua destroy()/reinit — cố ý, để bắt được bypass qua đổi provider giữa phiên).
- [x] `AdManager().exportSignedBypassAuditTrail()` — ký bằng ĐÚNG hạ tầng `signJsonPayload` (compliance_signing.dart) đã dùng chung cho compliance report (T96) + incident bundle (T125), cùng 1 khoá on-device.
- [x] `tool/bypass_audit_replay.dart` — CLI verify + in timeline, mirror đúng `tool/incident_replay.dart`.
- [x] Hoàn toàn offline — không network call nào, không phụ thuộc server.
- [x] Test (`test/bypass_audit_trail_test.dart`, 8 case): record đúng field + thứ tự; ring buffer cap đúng; ký xong verify đúng qua `verifySignedJsonPayload`; payload bị sửa 1 ký tự → verify fail; wiring thật qua `AdManager().showAppOpenAd`/`showRewardedAd` — bypass=true ghi đúng, bypass=false không ghi gì.

**Phạm vi đã thu hẹp có chủ ý:** không track riêng `dryRun` — đó là 1 cờ CẤU HÌNH cấp phiên (`AdSafetyParams.dryRun`), không phải 1 lệnh gọi có "call site" cụ thể như 2 cái kia, và giá trị của nó đã lộ sẵn qua `AdSafetyConfig.getStatus()`/`AdSafetySnapshot.dryRun` — không phải 1 "cửa hậu ẩn" cần thêm audit trail riêng.

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/bypass_audit_trail_test.dart` — gọi `showAppOpenAd(bypassSafety: true)` thật, xác nhận `bypassAuditTrail` không throw/không co lại. Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.

**Xác nhận chạy thật trên thiết bị (2026-09-01):** pass trên emulator Pixel_10_Pro_XL và máy thật Samsung SM-S928B, `--dart-define=AD_PROVIDER_ADMOB=true`. Không phải chỉ `flutter analyze`.
