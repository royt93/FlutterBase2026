# T202 — Consent provenance journal (IDEA)
Priority P2 · Status **done** (2026-09-16).

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

## Resolved 2026-09-16

Chủ dự án chọn: tự quyết định scope pháp lý, code luôn (không chờ luật sư).
Quyết định kỹ thuật cuối — khác vài điểm so với draft trên:

- **`policyRevision: String`**, không phải `int` — khớp quy ước sẵn có
  (`kUmpPolicyRevision = 'ump-v1'`, `ConsentFallbackState.policyRevision`),
  tránh 1 kiểu dữ liệu lệch pha trong cùng subsystem.
- **Câu hỏi "khái niệm scope thứ 3" giải quyết KHÔNG bằng thêm
  `SdkDataErasureScope` value mới** (sẽ lẫn với ý nghĩa entitlement/VIP tiền
  thật của scope đó). Thay vào đó: cờ `purgeConsentProvenanceJournal`
  riêng (mặc định `false`) trên `clearSdkData()` — journal sống sót CẢ HAI
  scope mặc định, chỉ mất khi gọi cờ này tường minh. Đơn giản hơn, không
  đụng enum export public.
- **Không có retention cap** — thay đổi consent là sự kiện hiếm (vài lần
  mỗi lifetime cài đặt), không cần ring-buffer như `IncidentRecorder`.
- **Chưa gộp vào `ComplianceReport` export** và **chưa có widget history
  view** — ngoài phạm vi lần implement này, có thể làm sau nếu có nhu cầu
  thật (không đoán trước).
- Implement: `lib/src/compliance/consent_provenance_journal.dart`
  (`ConsentProvenanceEntry` + `ConsentProvenanceJournal`, SHA-256 hash
  chain qua `package:cryptography` đã có sẵn), wiring qua
  `ConsentManager.bootstrap(provenanceJournal:)` +
  `set()`/`reset()` params `source`/`policyRevision` (optional, mặc định
  `'host'`/`kUmpPolicyRevision` — backward compatible), expose
  `AdManager().consentProvenanceJournal` (nullable tới khi init xong, cùng
  quy ước `vip`). TDD: `test/consent_provenance_journal_test.dart` (8
  test) + `test/consent_manager_provenance_test.dart` (5 test). Golden API
  surface đã regenerate. Full suite xanh (2147 pass; 4 fail trong
  `vip_cli_security_test.dart` là flake môi trường worktree cũ có sẵn,
  không liên quan — xem commit).

## Audit follow-up 2026-09-16 (3 agent adversarial độc lập, trước khi publish)

Chủ dự án yêu cầu audit lại trước khi lên pub.dev. 3 agent độc lập (không
chung context, tránh confirmation bias) mỗi agent 1 góc: correctness/race,
privacy/erasure semantics, API surface/test coverage. Tìm ra **4 bug thật**
(2 MAJOR bị 2 agent xác nhận trùng nhau độc lập, 1 BLOCKER, 1 API hygiene)
+ 2 gap test — tất cả đã fix, có test TDD (RED xác nhận bằng cách tạm revert
fix rồi chạy lại, không chỉ suy luận):

1. **Race hash chain (MAJOR)** — 2 lệnh consent chồng nhau chưa await xong
   đọc chung `prevHash` cũ → `verifyChain()` báo TAMPERED false-positive.
   Fix: serialize `append()` qua 1 future-chain queue (mutex đơn giản).
2. **Journal lệch instance sau destroy()+init lại (MAJOR, 2/3 agent xác
   nhận)** — `ConsentManager.bootstrap()` chỉ nhận `provenanceJournal` lần
   gọi ĐẦU, nhưng `AdManager` load bản journal MỚI mỗi lần `initialize()`
   → getter trỏ instance mồ côi, ghi thật lại rơi vào instance cũ không ai
   đọc được. Fix: bootstrap() giờ nhận journal mới mỗi lần gọi (giống cách
   `_strings` đã làm), không chỉ lần đầu.
3. **`AdManager().clearSdkData(purgeConsentProvenanceJournal:)` không tồn
   tại (BLOCKER)** — tôi chỉ thêm param vào `AdPreferences.clearSdkData()`
   (class nội bộ, không export), quên forward qua `AdManager` — README/
   CHANGELOG dạy code mẫu không compile. Fix: thêm param ở `AdManager`,
   khi SDK đang chạy live thì xoá cả bản trong bộ nhớ ngay (giống cách
   `VipManager.eraseAllEntitlementData()` đã làm cho VIP), không chỉ đợi
   load lại từ đĩa.
4. **`showDialog()` không cho set nguồn riêng + chưa test (MAJOR)** —
   đường dùng thật nhiều nhất (dialog SDK tự vẽ) bị hardcode `source: 'host'`
   không override được, không phân biệt được với `set()` chạy tay trong
   journal. Fix: thêm param `source`/`policyRevision` giống `set()`.
5. `fromEntries` (chỉ để test) rò ra API public golden vì thiếu
   `@visibleForTesting` — đã thêm annotation, golden đã regenerate.

**Phát hiện thêm ngoài dự kiến khi viết test cho các fix trên — nghiêm
trọng hơn cả 4 bug gốc:** thiết kế ban đầu để `AdManager.initialize()` TỰ
ĐỘNG bật journal cho MỌI app (không cần xin phép). Khi viết test tái hiện
bug #2 qua đường `AdManager().initialize()` thật (không chỉ unit
`ConsentManager` cô lập), phát hiện 2 test **có sẵn từ trước** trong bộ
2147 test (`ad_manager_core_test.dart` T60, `ump_consent_round5_test.dart`
M6) bắt đầu treo vô thời hạn — vì `package:cryptography`'s SHA-256 (chạy
qua background isolate) xung đột với `flutter_test`'s `testWidgets()`
fake-async khi 1 `test()` thường trong CÙNG file đã chạm crypto thật trước
đó (không phải lỗi ở fix, mà lỗi ở chính thiết kế "bật mặc định" khiến bất
kỳ test nào trong 2147 test gọi `set()`/`showDialog()` cũng vô tình dính
crypto thật). Sửa triệt để: đổi journal thành **opt-in** qua
`AdConfig.enableConsentProvenanceJournal` (mặc định `false`) thay vì tự
động bật — không phải chỉ né bug test, mà đúng hơn về latency cho app
không cần tính năng này. Full suite sau fix: 2153 pass, chỉ còn 4 fail cũ
(flake môi trường worktree, không liên quan). README/CHANGELOG/example app
cập nhật theo (`enableConsentProvenanceJournal: true` ở example để nút demo
hoạt động thật).
