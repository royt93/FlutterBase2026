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
