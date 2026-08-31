# T125 — Idea: Offline incident recorder + replayable support bundle

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P3 · **Status:** ✅ done (mechanism only — chưa auto-wire vào AdManager, xem ghi chú)
- **Files:** `lib/src/compliance/incident_recorder.dart` (mới), `lib/src/compliance/compliance_signing.dart` (thêm `SignedPayload`/`signJsonPayload`/`verifySignedJsonPayload`, generic hoá phần ký), `tool/incident_replay.dart` (mới), test `test/incident_recorder_test.dart` (mới)

## Vấn đề

Diagnostics/report là snapshot; race "không hiện ad" thường cần chuỗi trạng thái trước đó và khó tái tạo trên máy publisher. [đồng thuận 3 nguồn]

## Việc đã làm

- [x] `IncidentRecorder` (ring buffer nhỏ, mặc định capacity=200, KHÔNG phải `AdEventLog` — cái đó 5000 entry, full event payload, đã persist; recorder này chỉ giữ state-transition gần nhất). Mỗi `IncidentEntry` = `label` (chuỗi tự do, không enum) + `AdSdkStateSnapshot` (tái dùng type T109 có sẵn) + `deltaMs` tương đối so với entry trước — KHÔNG dùng wall-clock timestamp tuyệt đối vì máy ghi và máy publisher replay không cùng đồng hồ
- [x] `redactedConfigFingerprint(AdConfig)` — provider + có/không có sub-config + toàn bộ `AdSafetyParams` (numeric, không nhạy cảm). KHÔNG bao giờ chứa sdkKey/ad-unit ID
- [x] `IncidentBundle` (entries + fingerprint + generatedAtMs) → `toJsonString()`/`fromJsonString()`
- [x] Ký Ed25519: TÁI DÙNG hạ tầng `compliance_signing.dart` thật (cùng `_secureKeySeed`, cùng key-pair on-device với `signComplianceReport`) — thêm `SignedPayload`/`signJsonPayload`/`verifySignedJsonPayload` generic (payload JSON bất kỳ) cạnh type `SignedComplianceReport` cũ, KHÔNG đổi shape `reportJson` cũ (tool verify cũ + mọi export cũ không vỡ)
- [x] `tool/incident_replay.dart` — CLI thuần `dart run` (không phụ thuộc Flutter, giống `verify_compliance_report.dart`), verify chữ ký rồi in timeline theo thứ tự `+Nms label -> snapshot`. Hoàn toàn local, không network. Smoke test tay: tạo bundle mẫu, `dart run tool/incident_replay.dart <path>` in đúng timeline + `signature: VALID`
- [x] Test (`test/incident_recorder_test.dart`, 8 test): ring buffer đúng thứ tự + deltaMs + capacity-drop + clear() reset baseline; `redactedConfigFingerprint` không chứa ad-unit ID; round-trip JSON giữ nguyên chuỗi entry; `replayIncidentBundleJson` (hàm logic thuần `tool/incident_replay.dart` dùng) tái tạo ĐÚNG chuỗi đã ghi; ký/verify qua `verifySignedJsonPayload`; payload bị sửa 1 ký tự → verify fail

## Ghi chú

- **CHƯA auto-wire vào `AdManager`**: đây là scope cắt có chủ đích. Ticket chỉ đòi cơ chế recorder/export/replay (4 checkbox gốc), không đòi tự động ghi mọi state-transition thật trong `ad_manager.dart` (file 7000+ dòng, rủi ro cao hơn nhiều so với build cơ chế). Host/ticket tương lai gọi `recorder.record(label, AdSdkStateSnapshot(...))` tại các điểm chuyển trạng thái họ quan tâm (consent đổi, connectivity đổi, adapter init xong...), hoặc wire tự động là việc riêng.
- `SignedPayload` tách riêng khỏi `SignedComplianceReport` (không tái dùng 1 class chung) — cố ý, để field `reportJson` của report cũ không bao giờ đổi tên/shape.

## QA bổ sung (round-27 QA-hardening)

- [ ] CHƯA thêm integration test — cơ chế `IncidentRecorder` cố ý chưa auto-wire vào `AdManager` (xem ghi chú gốc), nên không có điểm chạm public qua `AdManager()` để test qua app thật. Cần ticket riêng nếu quyết định auto-wire.
