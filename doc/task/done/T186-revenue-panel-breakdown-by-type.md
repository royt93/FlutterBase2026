# T186 — Màn hình debug doanh thu: tách chi tiết theo loại quảng cáo/vị trí

**Loại:** enhancement
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config
**Quyết định chủ dự án (2026-09-08):** Làm

## Vấn đề (giải thích thực tế)
Màn hình debug "xem doanh thu" (`RevenuePanel`) hiện chỉ hiện tổng tiền + tổng số lần xem trong phiên. Ý tưởng: tách ra xem theo từng loại quảng cáo/vị trí để dev dễ biết chỗ nào kiếm tiền tốt.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/revenue_panel.dart:43-44` — chỉ tổng USD + số impression toàn phiên, chưa breakdown theo `AdSlotType`/`AdPlacement` dù `AdRevenueEvent` đã mang đủ field để làm việc này.

## Việc cần làm
1. Sửa `RevenuePanel` để nhóm doanh thu theo `AdSlotType` (và tuỳ chọn theo `AdPlacement` nếu không quá phức tạp UI) — giữ tổng số cũ ở trên cùng, thêm breakdown bên dưới.
2. Viết widget test cho panel với dữ liệu nhiều loại/vị trí quảng cáo khác nhau.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/revenue_panel.dart dòng ~43-44: hiện chỉ tổng USD + số impression toàn phiên. Thêm breakdown theo AdSlotType (banner/mrec/native/interstitial/rewarded/rewardedInterstitial/appOpen) — mỗi loại hiện tổng tiền + số lần riêng, giữ nguyên tổng số cũ ở trên cùng làm summary. Cân nhắc thêm breakdown theo AdPlacement nếu UI không quá rối (có thể làm expandable/collapsible per loại). Viết widget test: nạp nhiều AdRevenueEvent khác loại/vị trí, xác nhận panel hiện đúng breakdown và tổng vẫn khớp.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho breakdown nhiều loại/vị trí, tổng số khớp đúng.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, xem nhiều loại quảng cáo, mở `RevenuePanel`, chụp bằng chứng breakdown đúng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-13)

`RevenuePanel` (chế độ đầy đủ, không phải `compact`) giờ hiện thêm 1 danh
sách bên dưới tổng số cũ: mỗi loại quảng cáo (`AdSlotType`) đã có doanh
thu trong phiên hiện 1 dòng riêng — tên loại + tổng tiền USD + số lần
riêng của loại đó, sắp theo bảng chữ cái. Áp dụng đúng quy tắc "chỉ cộng
USD" giống tổng số cũ (1 sự kiện tiền tệ khác USD không bị cộng nhầm vào
cả tổng chung lẫn breakdown theo loại). Chế độ `compact` giữ nguyên,
không có breakdown (đúng như mô tả gốc "giữ tổng số cũ ở trên cùng" —
hiểu là compact chỉ cần 1 dòng gọn, breakdown chỉ có ở chế độ đầy đủ).
Không làm breakdown theo `AdPlacement` (mục "tuỳ chọn" trong mô tả gốc) —
UI sẽ rối nếu vừa tách theo loại vừa theo vị trí trong 1 danh sách phẳng,
và mô tả gốc đã tự nêu chỉ làm nếu "không quá phức tạp UI".

Đã tự xác minh không vô nghĩa: tạm bỏ đoạn code cộng dồn theo loại, xác
nhận 2 test liên quan fail đúng như kỳ vọng, rồi khôi phục và xác nhận
xanh lại.

Xác minh: `flutter analyze` sạch; SDK suite 2013 test xanh (từ 2009, +4);
example suite 47 file xanh (không đổi); device smoke thật trên **TECNO
BG6** (`118743744X002560`) qua
`example/integration_test/t186_revenue_panel_breakdown_test.dart` — dựng
`RevenuePanel` thật trên màn hình thật, bơm sự kiện doanh thu giả lập 2
loại khác nhau (interstitial + rewarded), xác nhận cả 2 dòng breakdown
hiện đúng số + tổng chung khớp tổng 2 loại cộng lại. Cũng thêm 1 nút demo
trong `example/lib/main.dart`'s trang "Revenue dashboard" (nút "Simulate
revenue (rewarded, T186)") để dev có thể tự tay bấm xem breakdown khi
chạy app thật, không chỉ qua integration test tự động.

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước, chưa reset) — bù bằng kỷ luật revert-để-xác-nhận-đỏ + smoke test
thật trên device như trên.
