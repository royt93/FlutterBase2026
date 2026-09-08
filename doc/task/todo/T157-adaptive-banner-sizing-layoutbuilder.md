# T157 — Banner quảng cáo vỡ khung khi đặt trong container nhỏ hơn toàn màn hình

**Loại:** enhancement
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** codex + agy (2 nguồn độc lập)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Banner quảng cáo hiện đang đo kích thước theo TOÀN MÀN HÌNH (`MediaQuery.of(ctx).size.width`) thay vì theo khung chứa nó. Nếu dev đặt banner trong 1 khung nhỏ hơn (VD popup, sidebar, màn hình chia đôi trên tablet), banner vẫn xin kích thước to như toàn màn hình → có thể bị tràn ra ngoài khung, vỡ giao diện, và vi phạm chính sách hiển thị của Google AdMob (kích thước banner phải khớp không gian thật).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:358-360` — tính chiều rộng Adaptive Banner bằng `MediaQuery.of(ctx).size.width`.

## Việc cần làm
1. Bọc phần tính kích thước bằng `LayoutBuilder`, ưu tiên lấy `constraints.maxWidth`; chỉ fallback về `MediaQuery.of(context).size.width` khi `constraints.maxWidth` unbounded (`double.infinity`).
2. Kiểm tra `mrec_ad_widget.dart` có logic tương tự cần đồng bộ không (MREC thường là kích thước cố định 300x250 nên có thể không cần, nhưng verify).
3. Thêm test: đặt `BannerAdWidget` trong `SizedBox(width: 200)` — xác nhận banner xin đúng kích thước ~200, không phải kích thước toàn màn hình.
4. Thêm demo trong `example/`: 1 màn hình có banner trong popup/dialog hẹp và 1 banner toàn màn hình bình thường, so sánh trực quan.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/banner_ad_widget.dart dòng ~358-360: tính chiều rộng Adaptive Banner đang dùng MediaQuery.of(ctx).size.width (toàn màn hình) thay vì theo khung chứa thật. Bọc bằng LayoutBuilder, ưu tiên constraints.maxWidth; chỉ fallback về MediaQuery khi constraints.maxWidth là double.infinity (unbounded, VD khi banner không nằm trong constraint nào rõ ràng). Kiểm tra xem có cần áp dụng tương tự cho mrec_ad_widget.dart không (MREC thường kích thước cố định nên khả năng không cần, verify trước khi sửa). Viết widget test: BannerAdWidget trong SizedBox(width: 200, height: 60) xác nhận kích thước banner request đúng ~200 không phải full-screen-width; test banner ngoài mọi constraint (unbounded) vẫn fallback về MediaQuery đúng như cũ, không breaking. Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho cả case constrained (LayoutBuilder) và unbounded (fallback MediaQuery); test không breaking hành vi cũ cho banner toàn màn hình bình thường.
3. Demo trong `example/` (popup hẹp + toàn màn hình) + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device (thử cả điện thoại và tablet/màn hình lớn nếu có), xác nhận banner trong popup không tràn khung.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
