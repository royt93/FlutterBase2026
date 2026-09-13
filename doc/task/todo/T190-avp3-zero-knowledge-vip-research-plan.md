# T190 — Đổi cách khoá VIP sang cơ chế phức tạp/an toàn hơn (NGHIÊN CỨU, CHƯA CODE — RỦI RO CAO)

**Loại:** exclusive-feature (idea, rủi ro cao)
**Ưu tiên:** P3 (nghiên cứu, không ưu tiên gấp)
**Trạng thái:** todo (research-only, KHÔNG code ngay)
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Chưa làm, chỉ ghi plan vào backlog — RỦI RO CAO NHẤT trong toàn bộ backlog này, cần đặc biệt thận trọng

## Ý tưởng
Hệ thống khoá VIP hiện tại (Ed25519-signed keys, xem CLAUDE.md mục "VIP entitlement") đã chạy ổn định hơn 1 năm, kiểm tra kỹ hơn 12 lần (audit round 6 tới 41+). Ý tưởng là đổi sang cách khoá phức tạp hơn, khó bẻ hơn (mô tả gốc: "Merkle tree + epoch + device-secret masking" — thuật ngữ kỹ thuật, chưa cần hiểu chi tiết ở giai đoạn này).

## Rủi ro đã xác nhận với chủ dự án
Đụng vào hệ thống VIP đang chạy tốt để đổi sang cách mới phức tạp hơn — dễ làm hỏng cái đang ổn định (đang thu tiền thật từ VIP), lợi ích thực tế (khó bẻ khoá hơn) chưa rõ ràng có cần thiết ngay hay không. **Đây là ý tưởng RỦI RO CAO NHẤT trong toàn bộ đợt audit này** — chủ dự án chọn KHÔNG động vào, chỉ ghi lại để tham khảo.

## Việc cần làm (CHỈ giai đoạn nghiên cứu — KHÔNG code, KHÔNG động vào `vip_manager.dart`/`signed_vip_key.dart` hiện có)
1. Đọc kỹ hệ thống khoá VIP hiện tại (`packages/ad_sdk/lib/src/vip/signed_vip_key.dart`, `vip_manager.dart`) và lịch sử audit liên quan (round 6-41+, đặc biệt các round có nhắc AVP1/AVP2) để hiểu đúng cơ chế đang có và LÝ DO nó được thiết kế như vậy.
2. Nghiên cứu: điểm yếu THẬT SỰ nào của cơ chế hiện tại (nếu có) mà cách mới muốn giải quyết — không nghiên cứu chỉ vì "phức tạp hơn nghe an toàn hơn".
3. Nếu có điểm yếu thật: đánh giá mức độ nghiêm trọng, tần suất bị khai thác thực tế (nếu có bằng chứng), so với chi phí/rủi ro khi thay đổi.
4. Đề xuất: có cách nào tăng cường an toàn ở mức RỦI RO THẤP HƠN không (VD chỉ thắt chặt tham số hiện có — thời hạn key, tần suất CRL check — thay vì đổi toàn bộ kiến trúc)?
5. Kết luận rõ ràng: có nên làm không, và nếu có thì ở mức độ nào (toàn bộ redesign, hay chỉ tăng cường tham số).

## Prompt để chạy (giai đoạn nghiên cứu — TUYỆT ĐỐI KHÔNG SỬA CODE)
```
Đọc kỹ packages/ad_sdk/lib/src/vip/signed_vip_key.dart, vip_manager.dart, và doc/audit/ (các round có nhắc AVP1/AVP2, VIP key signing) để hiểu đúng cơ chế khoá VIP hiện tại và lý do thiết kế. TUYỆT ĐỐI KHÔNG sửa bất kỳ file nào trong lib/src/vip/. Viết bản kế hoạch (design doc) trả lời: (1) điểm yếu THẬT SỰ nào của cơ chế hiện tại cần giải quyết (nếu không tìm thấy điểm yếu cụ thể, ghi rõ "không tìm thấy lý do kỹ thuật thuyết phục để thay đổi"), (2) nếu có điểm yếu, mức nghiêm trọng thực tế ra sao, (3) có giải pháp rủi ro thấp hơn (chỉ tăng tham số hiện có) giải quyết được không, (4) kết luận cuối: có nên redesign toàn bộ không. Cập nhật kết luận vào file task T190 này, không sửa code.
```

## Tín hiệu kết thúc (KHÔNG code, KHÔNG push code)
Dừng khi đã điền đầy đủ mục "Kết luận nghiên cứu" bên dưới. KHÔNG commit code mới, KHÔNG động vào file trong `lib/src/vip/`. Chờ chủ dự án đọc và quyết định — đây là quyết định RỦI RO CAO, cần chủ dự án tự cân nhắc kỹ trước khi cho phép bất kỳ code nào được viết.

## Kết luận nghiên cứu (2026-09-13)

**Không sửa bất kỳ file nào trong `lib/src/vip/` — chỉ đọc để nghiên
cứu, đúng yêu cầu.**

### (1) Điểm yếu THẬT SỰ nào của cơ chế hiện tại?

Đã đọc kỹ `signed_vip_key.dart` (379 dòng) và `vip_manager.dart` (1798
dòng). Cơ chế hiện tại (AVP1/AVP2, Ed25519 offline-signed + CRL + key
rotation + per-app bundle binding + per-device one-time-use) đã rất kỹ
lưỡng — 12+ vòng audit độc lập đã rà soát.

**Chỉ tìm thấy 1 điểm yếu thật sự, và nó là CHỦ Ý, không phải sơ suất**:
khoá VIP không có "one-time-use TOÀN CỤC" — chỉ chặn dùng lại TRÊN CÙNG 1
thiết bị (comment gốc trong code, `signed_vip_key.dart` dòng 119: "A
leaked key can still be reused on other devices — true global one-time-
use needs a server"). Nghĩa là: nếu 1 key bị lộ ra ngoài (VD đăng công
khai), nhiều thiết bị khác nhau đều dùng được — không có cách nào chặn
trên thiết bị, vì thiết kế cố ý KHÔNG dùng server trung tâm (offline-
first, đã ghi rõ trong memory: "vip-offline-gate-and-qa-hashes-are-
features" — đây là quyết định có chủ đích, từng bị audit flag rồi xác
nhận giữ nguyên).

**Kết luận (1): điểm yếu duy nhất tìm được (cross-device replay) là hệ
quả TẤT YẾU của chính yêu cầu "không cần server" — không phải lỗi thiết
kế có thể sửa bằng cách đổi thuật toán mã hoá.**

### (2) Mức độ nghiêm trọng thực tế

Thấp trong thực tế: key phải bị LỘ RA NGOÀI trước (VD đăng công khai/rò
rỉ) thì mới khai thác được — không phải lỗ hổng có thể tự khai thác từ
xa. Không có bằng chứng ghi nhận đã từng bị khai thác thật (không tìm
thấy nhắc tới trong lịch sử audit round 6-41+ đã đọc).

### (3) "Merkle tree + epoch + device-secret masking" có giải quyết được
điểm yếu này không?

**KHÔNG.** Cả 3 kỹ thuật này đều là cách tổ chức/nén dữ liệu chữ ký hoặc
thêm ràng buộc theo thời gian (epoch) — không kỹ thuật nào trong 3 cái
này tạo ra được "one-time-use toàn cục" nếu không có server để các thiết
bị đối chiếu với nhau real-time. Nói cách khác: đổi sang kiến trúc phức
tạp hơn nhưng VẪN offline-only thì điểm yếu duy nhất đã xác định vẫn y
nguyên — chỉ có "trông phức tạp hơn", không giải quyết được vấn đề gốc.

### (4) Giải pháp rủi ro thấp hơn (thắt chặt tham số) có đủ không?

Có — và đã sẵn có, không cần code thêm gì:
- **Thời hạn key (`expiresAt`, AVP2)**: đã có sẵn field này, do người
  mint key (`tool/vip_mint.dart`) tự quyết định khi tạo, không phải hạn
  chế của SDK. Muốn "thắt chặt" chỉ cần mint key với thời hạn ngắn hơn —
  không cần đổi code.
- **Tần suất kiểm tra CRL**: `refreshRevocationList()` là hàm HOST TỰ GỌI
  (không có timer tự động bên trong SDK) — tần suất hoàn toàn do app
  dùng SDK quyết định. Muốn kiểm tra thường xuyên hơn, host chỉ cần gọi
  hàm này thường xuyên hơn — cũng không cần đổi code SDK.
- Nếu key bị lộ: đã có key rotation (danh sách public key phân tách bởi
  dấu phẩy) — rút khoá bị lộ khỏi danh sách + phát hành key mới, quy
  trình đã có sẵn, không cần redesign.

### Khuyến nghị cuối

**KHÔNG nên redesign toàn bộ kiến trúc.** Không tìm thấy lý do kỹ thuật
thuyết phục để thay đổi — điểm yếu duy nhất tìm được (cross-device
replay của key bị lộ) là hệ quả tất yếu của yêu cầu "không server", và
"Merkle tree + epoch + device-secret masking" không giải quyết được nó
dù có làm hay không (vẫn cần server để có one-time-use toàn cục thật
sự). Nếu muốn siết chặt hơn, dùng ngay các đòn bẩy tham số đã có sẵn
(thời hạn key ngắn hơn lúc mint, gọi `refreshRevocationList()` thường
xuyên hơn, rotation nhanh khi phát hiện lộ key) — không cần bất kỳ thay
đổi code nào trong `lib/src/vip/`.
