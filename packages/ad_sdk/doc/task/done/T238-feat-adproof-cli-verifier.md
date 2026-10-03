# T238 — Tính năng mới: CLI verify độc lập file `.adproof` của Flight Recorder

- **Loại:** New Feature
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done

## Bằng chứng hoàn thành

- **Process-level tests:** `test/verify_adproof_tool_test.dart` — 11/11 pass. Bao phủ usage/missing-file exit 2; valid bundle `VALID`/exit 0; field tamper, reorder, delete-middle, append forged, direct `previousHash` tamper (re-sign để signature vẫn hợp lệ nhưng chain bị bắt), signature tamper, public-key tamper, malformed JSON — tất cả `INVALID`/exit 1.
- **Runtime:** CLI chạy bằng plain `dart run tool/verify_adproof.dart ...`; chỉ dùng stdlib + dependency `cryptography` đã có, không thêm package, không cần Flutter engine/simulator.
- **Device thật:** `example/integration_test/t231_flight_recorder_test.dart` xuất artifact từ TECNO BG6 Android 13 tại `/data/user/0/com.roy.admobwrapper/code_cache/t238_device.adproof`; host kéo bằng `adb run-as`, file 1125 bytes. CLI trả `VALID`, exit 0. Mutate 1 byte trong `fullscreenVisible` → CLI trả `INVALID`, exit 1.
- **Docs:** `README.md` có hướng dẫn threat model/command `.adproof`; `CLAUDE.md` command list cập nhật.
- **Format:** không đổi format `.adproof` hiện có.

## Acceptance Criteria

- [x] File `.adproof` hợp lệ in `VALID`, exit 0.
- [x] Sửa field/xóa/reorder/append/`previousHash`/signature/public key → `INVALID`, exit 1.
- [x] File thiếu/không đọc được/sai usage → stderr rõ, exit 2.
- [x] Plain `dart run`, không Flutter engine.
- [x] README/CLAUDE cập nhật, không hardcode version.
- [x] Không đổi `.adproof` format, không dependency mới.
- [x] Test liên quan pass; device export + CLI proof pass.

## Vấn đề (Why)

T231 đã có hàm Dart công khai `verifySignedFlightRecorderBundle(String)` tại `packages/ad_sdk/lib/src/compliance/ad_flight_recorder.dart:477-486`, kiểm tra cả chữ ký Ed25519 và hash chain. Nhưng thư mục `packages/ad_sdk/tool/` hiện chỉ có:

- `verify_compliance_report.dart`
- `bypass_audit_replay.dart`
- `incident_replay.dart`

Không có CLI dành cho `.adproof`. Điều này mâu thuẫn với chính kế hoạch kiểm thử T231: `doc/task/done/T231-flagship-ad-compliance-flight-recorder.md:24` yêu cầu "On-device test: Xuất file bằng chứng thực tế và verify qua tool CLI". Hiện chỉ có unit/integration gọi hàm trong SDK; người nhận file tranh chấp (support/legal/network reviewer) không có lệnh độc lập để xác minh artifact thật ngoài ứng dụng.

## Đề xuất giải pháp

Thêm `tool/verify_adproof.dart` theo đúng UX/exit-code của `tool/verify_compliance_report.dart`:

```bash
dart run tool/verify_adproof.dart <path-to-exported.adproof>
# VALID  -> exit 0
# INVALID -> exit 1
# usage/read error -> exit 2
```

Tool phải kiểm tra **cả** chữ ký Ed25519 lẫn từng liên kết/hash canonical trong chain, không chỉ parse JSON hoặc gọi một nửa verification. Ưu tiên code dùng chung tối thiểu nếu plain `dart run` không thể import toàn bộ Flutter SDK; không kéo dependency mới.

## Kế hoạch kiểm thử

- Unit/tool test bằng fixture sinh từ `signFlightRecorderBundle`: valid, field tamper, reorder, delete-middle, append-forged, malformed JSON, missing file.
- CLI process test kiểm tra chính xác stdout/stderr/exit code 0/1/2.
- Integration/device: export `.adproof` thật từ `t231_flight_recorder_test.dart`, copy ra host, chạy CLI và xác nhận `VALID`; mutate 1 byte và xác nhận `INVALID`.

## Prompt vòng lặp (Loop Prompt)

Triển khai task T238 theo quy trình TDD chuẩn:
1. Viết process-level test RED cho command chưa tồn tại và các exit code.
2. Dùng stdlib + dependency `cryptography` đã có; không thêm package mới.
3. Verify cả signature lẫn hash chain; test tamper thật chứ không chỉ parse failure.
4. Tín hiệu kết thúc vòng lặp: audit độc lập >9/10, đủ test pyramid, chạy tool trên export device thật, rồi mới commit/push.
