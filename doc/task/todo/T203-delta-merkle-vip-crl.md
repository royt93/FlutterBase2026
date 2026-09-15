# T203 — Delta/Merkle VIP revocation transparency (EXCLUSIVE)
Priority P3 · Status research-only.

Full signed CRL không scale tốt. Thiết kế signed Merkle root + delta membership/non-membership proofs, anti-rollback, offline cache; Phase 1 threat-model/benchmark, Phase 2 dual-read AVP3 fallback AVP2. Gzip full CRL dễ hơn nhưng không giải quyết dài hạn; online API phá offline promise.

DoD: canonical encoding, rotation, root pinning, downgrade/privacy analysis, migration plan, test vectors/benchmark. Unit proof/rollback/corruption; widget VIP status; integration offline redemption; airplane-mode device smoke. Chưa thay production CRL nếu owner chưa duyệt.

Loop prompt: audit design+score /10, unit/widget/integration test vectors và device smoke prototype; >9/10 mới commit+push prototype, ngược lại loop.

## Kết luận nghiên cứu (2026-09-15)

### Cơ chế CRL hiện tại (đã đọc kỹ code thật)

Full signed CRL **đã hoạt động thật**, không phải ý tưởng: `VipManager`
(`lib/src/vip/vip_manager.dart:1511-1583`, `refreshRevocationList()`).
Ed25519-signed (dùng chung cơ chế key/key-rotation với `redeemSignedKey`),
host tự gọi định kỳ qua `VipRevocationProvider.fetchSignedCrl()`
(`lib/src/vip/vip_revocation_provider.dart:1-35` — transport do host tự
chọn: HTTP/Firebase Remote Config/...). Fail-open toàn diện: fetch lỗi/null/
chữ ký sai/`issuedAt` cũ hơn bản đang có → giữ nguyên cache cũ, KHÔNG BAO
GIỜ chặn redemption hợp lệ chỉ vì CRL không tải được. Danh sách thu hồi chỉ
là `Set<String>` các `kid` bị thu hồi (`vip_manager.dart:178`).

### Quy mô thật — đây là điểm mấu chốt

Đây là hệ thống VIP kiểu **license key mint thủ công** (qua
`tool/vip_crl_mint.dart`/`tool/vip_mint.dart`), KHÔNG phải theo tài khoản
người dùng hàng loạt. Danh sách thu hồi tăng theo số key bị lộ/hoàn tiền —
thực tế là hàng chục/hàng trăm entry, không phải hàng triệu. Một JSON/text
list vài nghìn `kid` tối đa vài chục KB — Merkle-tree/CT-log-style delta
proof (thiết kế cho hàng tỷ chứng chỉ, như Certificate Transparency) **không
tương xứng quy mô này**.

### Quan hệ với T190 — không độc lập, mà trùng lặp

T203's Phase 2 giả định "AVP3" tồn tại (dual-read AVP3 fallback AVP2) —
nhưng T190 (`doc/task/todo/T190-avp3-zero-knowledge-vip-research-plan.md`,
đã có "Kết luận nghiên cứu" 2026-09-13) đã kết luận **KHÔNG nên tạo
AVP3/redesign**: điểm yếu duy nhất tìm được (cross-device replay key bị lộ)
là hệ quả tất yếu của thiết kế "không cần server" cố ý của toàn hệ thống
VIP, và chính T190 đã cân nhắc ý tưởng "Merkle tree + epoch + device-secret
masking" — kết luận nó KHÔNG giải quyết được điểm yếu đó (vẫn cần server để
có one-time-use toàn cục thật, phá vỡ chính lời hứa "offline" của SDK).
T203 không hề độc lập với T190 — nó dùng lại đúng kỹ thuật T190 đã cân nhắc
và bác bỏ, và Phase 2 của nó phụ thuộc vào một AVP3 mà T190 khuyến nghị
KHÔNG nên tạo.

### Phase 1 (chỉ threat-model/benchmark, chưa code) có tương xứng không?

Không. Với quy mô thực tế (vài trăm entry, vài chục KB), Merkle delta-proof
giải quyết một vấn đề (scale tới hàng tỷ entry) không tồn tại ở quy mô này,
và về mặt bảo mật, T190 đã chứng minh nó không đóng góp gì thêm so với thiết
kế hiện tại.

### Effort & khuyến nghị

Phase 1 (threat-model/benchmark đơn thuần, không code): ~1-2 ngày nếu làm.
**Khuyến nghị: không nên làm cả Phase 1** — nên đóng task này hoặc gộp
thành 1 dòng tham chiếu tới T190 ("đã có kết luận, không redesign VIP"),
trừ khi chủ dự án có lý do cụ thể KHÁC với lý do task hiện ghi (ví dụ:
băng thông tải CRL rất chậm/đắt ở một thị trường cụ thể — đó là một vấn đề
khác, cần đo đạc thật trước, không phải lý do "scale" nêu trong task này).
