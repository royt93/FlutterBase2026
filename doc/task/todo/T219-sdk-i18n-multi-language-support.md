# T219 — Đa ngôn ngữ (i18n) cho dialog/widget/feature/helper của SDK

**Loại:** new-feature (kiến trúc)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** user request (2026-09-13)

## Vấn đề (giải thích thực tế)

SDK hiện có UI hiển thị trực tiếp cho người dùng cuối (consent dialog, CCPA
opt-out toggle, VIP redeem screen, debug overlay, ...). App host tích hợp
SDK có thể có người dùng nói nhiều ngôn ngữ khác nhau, nhưng SDK hiện chỉ
cung cấp string tiếng Việt làm preset mặc định, không có preset tiếng Anh
hay ngôn ngữ khác, và không tự động theo locale máy.

## Hiện trạng đã audit (2026-09-13)

Pattern "host tự cấp string qua 1 class" đã tồn tại cho 3 nơi:
- `ConsentDialogStrings` (`lib/src/consent/consent_dialog_strings.dart`) —
  chỉ có preset `.vi`.
- `CcpaOptOutStrings` (`lib/src/consent/ccpa_opt_out_strings.dart`) — chỉ
  có preset `.vi`.
- `VipDialogStrings` (`lib/src/vip/vip_dialog_strings.dart`) — không có
  preset nào, host phải tự điền toàn bộ field.

Các widget/feature khác (banner, native, MREC, debug overlay
`DebugAdOverlay`, các demo trong `example/`) hiển thị text hard-code tiếng
Anh trực tiếp trong code, không đi qua bất kỳ string-class nào.

## Việc cần làm (đề xuất, cần bàn kỹ trước khi code — dùng brainstorming
skill hoặc hỏi lại nếu chưa rõ)

1. Quyết định kiến trúc: giữ pattern "string class do host cấp" (nhất
   quán với 3 class hiện có, không cần thêm dependency) hay chuyển sang
   `intl`/ARB (chuẩn Flutter, nhưng thêm dependency + build step).
2. Nếu giữ string-class: thêm preset `.en` (và có thể `.vi`, `.en` là 2
   preset tối thiểu) cho cả 3 class hiện có; xác định nơi nào KHÁC trong
   SDK hiển thị text cho end-user (không phải log dev) cần string-class
   tương tự (debug overlay của SDK — nếu end-user thấy được — không phải
   demo trong example/, vì example/ là code mẫu của host, không phải SDK).
3. Cân nhắc auto-detect locale máy (`Localizations.localeOf(context)`)
   làm fallback khi host không cấu hình rõ, thay vì luôn mặc định `.vi`.
4. KHÔNG đổi API hiện có theo cách breaking — mọi preset mới là bổ sung,
   field/class hiện có giữ nguyên.

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho mỗi preset ngôn ngữ mới + test không breaking cho preset
   `.vi` hiện có.
3. Widget test xác nhận dialog/UI thật render đúng preset được chọn.
4. README.md cập nhật mục hướng dẫn đa ngôn ngữ.
5. Audit độc lập (codex review --uncommitted), chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, đổi preset ngôn ngữ, xác nhận UI
   hiển thị đúng.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
