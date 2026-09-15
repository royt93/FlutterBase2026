# T202 — Consent provenance journal (IDEA)
Priority P2 · Status todo.

Lưu append-only lịch sử consent tối thiểu (source UMP/host/manual, policy revision, timestamp, region signal, hash chain), export cùng compliance report nhưng không raw PII. Khuyến nghị local-only, retention cap, opt-in export; server mạnh hơn nhưng tăng privacy/infra risk.

Research/DoD: threat model, schema/migration/redaction, T200 erase integration, regulator review. Tests unit tamper/rotation/erase; widget history; integration restart/export; offline/storage-full device smoke.

Loop prompt: audit thiết kế+score /10, test vectors unit/widget/integration và prototype smoke; >9/10 commit+push prototype, nếu research-only ghi rõ không push production.

## Quyết định chủ dự án (2026-09-15)
Research plan trước (giống T183/T189/T190/T191) — KHÔNG code ngay, chờ đọc kết luận bên dưới rồi quyết định.

## Kết luận nghiên cứu (2026-09-15)

### Cơ chế gần nhất hiện có (đã đọc kỹ code thật)

- `ConsentManager` (`lib/src/consent/consent_manager.dart`) chỉ **ghi đè**
  `ConsentSettings` hiện tại mỗi lần `set()`/persist — không có lịch sử,
  không có field "nguồn" (UMP/host/manual). `ConsentSettings` (các field
  `hasUserConsent`, `isAgeRestrictedUser`, `doNotSell`, `hasBeenAsked`,
  `askedAt`, `country`) không có provenance.
- `IncidentRecorder` (`lib/src/compliance/incident_recorder.dart:95-97`) là
  ring buffer nhỏ (200 entry, **chỉ sống trong bộ nhớ, không persist qua
  restart**), có field `IncidentEntry.clockRolledBackMs` (T199) — mẫu tốt để
  tham khảo cách encode JSON, nhưng KHÔNG có hash chain và KHÔNG phù hợp mục
  đích (mất hết khi tắt app).
- Không nơi nào trong `lib/` hiện có hash chain thật.
- `ComplianceReport` (`lib/src/compliance/compliance_report.dart:44-176`,
  `ComplianceReport.generate()`) là **snapshot tại 1 thời điểm**: chụp
  `ConsentSettings` hiện tại + `events` (từ `AdEventLog`) trong khoảng
  `[from,to]`. KHÔNG lưu lịch sử thay đổi consent qua thời gian — đây chính
  là khoảng trống T202 nhắm tới.

### Schema đề xuất (tối giản, theo đúng style `IncidentEntry`)

```dart
class ConsentProvenanceEntry {
  final DateTime at;
  final String source; // 'ump' | 'host' | 'manual'
  final int policyRevision;
  final bool hasUserConsent, isAgeRestrictedUser, doNotSell;
  final String? regionSignal; // consentCountry, KHÔNG phải geo thật/GPS
  final String entryHash; // SHA-256(prevHash + các field trên)
}
```

### Cơ chế chống giả mạo (tamper-evidence)

Ed25519 signing (`compliance_signing.dart`, T195) ký **toàn bộ document 1
lần lúc export** — không hợp cho từng entry ghi theo thời gian thực (mỗi
entry một lần ký sẽ tốn round-trip secure-storage per entry, không cần
thiết). Đơn giản hơn nhiều và đủ dùng: **SHA-256 hash chain** (mỗi entry
`hash = SHA256(hash trước + field của chính nó)`) — dùng ngay package
`cryptography` đã có sẵn trong `pubspec.yaml` (đã có `Sha256`), KHÔNG cần
thêm dependency mới.

### Câu hỏi cần chủ dự án quyết định — KHÔNG phải câu hỏi kỹ thuật thuần

Tương tác với T200 `AdManager().clearSdkData()`: nếu journal này rơi vào
`SdkDataErasureScope.everythingExceptEntitlements` (mặc định), nó bị xoá
cùng lần erase thông thường như mọi dữ liệu SDK khác — nhưng một số khung
pháp lý (GDPR Điều 17(3), CCPA) cho phép/đòi hỏi giữ lại **bằng chứng đã
từng xin/nhận consent** như "legal basis defense" ngay cả sau yêu cầu xoá
dữ liệu của người dùng. Chưa có tiền lệ nào trong code hiện tại để noi
theo, và đây là quyết định pháp lý thật (cần ý kiến luật sư/compliance của
dự án, không phải kỹ sư tự quyết): journal có nên có 1 scope RIÊNG (không
gộp vào `everythingExceptEntitlements`, cũng không phải
`allIncludingEntitlements` — 1 khái niệm thứ 3), hay chấp nhận bị xoá cùng
scope mặc định?

### Effort ước tính

~3-4 ngày: schema + hash chain + persist qua `SharedPreferences` với
retention cap (số entry tối đa hoặc theo thời gian) + gộp export vào
`ComplianceReport` + test unit tamper/rotation/corruption + widget history
view + integration restart/export + device smoke offline/storage-full.

### Khuyến nghị

**Nên research thêm câu hỏi pháp lý ở trên trước khi code** — quyết định
"giữ hay xoá journal khi host gọi erase" ảnh hưởng trực tiếp tới schema
(cần field `scope` riêng ngay từ đầu hay không) và tới chính DoD
"regulator review" mà task này tự đặt ra. Làm sai hướng này (code trước,
hỏi luật sau) rủi ro cao hơn lợi ích của việc code sớm — task còn lại các
phần kỹ thuật (schema, hash chain, retention, export) đều đã rõ ràng và
effort thấp, không phải điểm nghẽn.
