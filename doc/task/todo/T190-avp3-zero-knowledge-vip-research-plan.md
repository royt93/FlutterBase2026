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

## Kết luận nghiên cứu
(để trống, điền sau khi nghiên cứu xong)
