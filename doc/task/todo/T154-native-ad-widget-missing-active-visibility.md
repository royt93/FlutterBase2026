# T154 — Quảng cáo native tính lượt xem dù bị ẩn sau tab khác

**Loại:** bug (rủi ro chính sách mạng quảng cáo)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config, tự verify (đối chiếu banner/mrec đã fix round-31/39)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Trong app mẫu, khung chứa quảng cáo native đã được nạp nhưng chưa hiển thị (VD bị ẩn sau tab khác trong `IndexedStack`) vẫn bị tính là đang xem — tốn 1 lượt quảng cáo mà không ai thấy. Rủi ro: Google/AppLovin có quy định cấm tính quảng cáo không ai nhìn thấy, nếu họ phát hiện có thể phạt/khoá tài khoản quảng cáo. Banner và MREC đã được vá đúng vấn đề này ở round-31/round-39; native bị bỏ sót.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/native_ad_widget.dart` (toàn file) — không có tham số `active` và không dùng `VisibilityDetector`, trong khi `banner_ad_widget.dart:56,72` và `mrec_ad_widget.dart:34,43` đã được vá.
- Native ad mount trong 1 tab `IndexedStack` chưa từng active vẫn gọi `_initNative()` ngay trong `initState()` (dòng 119) bất kể tab có hiển thị hay không.
- Native không có auto-refresh nên không lặp lại liên tục như banner/mrec, nhưng lần load đầu vẫn tốn 1 request/impression cho nội dung chưa từng hiển thị.

## Việc cần làm
1. Thêm tham số `active` vào `NativeAdWidget` (mặc định `true`), và tích hợp `VisibilityDetector` giống banner/mrec — chỉ `_initNative()` khi thực sự visible/active.
2. Đảm bảo T153 (buildBanner/buildMrec active passthrough) và task này đồng bộ: sau khi cả 2 xong, có thể cân nhắc thêm `buildNative()` helper vào `AdScreenState` nếu chưa có.
3. Thêm log SafeLogger khi native ad bị trì hoãn init vì chưa active/visible.
4. Thêm demo trong `example/`: native ad trong tab `IndexedStack`, chứng minh không load cho tới khi tab active.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/native_ad_widget.dart: hiện không có tham số active và không dùng VisibilityDetector, khiến _initNative() (dòng ~119) chạy ngay trong initState() bất kể widget có hiển thị hay không — khác với banner_ad_widget.dart (dòng ~56,72) và mrec_ad_widget.dart (dòng ~34,43) đã được vá đúng vấn đề này ở round-31/39. Đọc kỹ cách 2 file đó implement active+VisibilityDetector, áp dụng tương tự cho NativeAdWidget (lưu ý native không auto-refresh nên logic có thể đơn giản hơn — không cần vòng lặp refresh, chỉ cần trì hoãn init lần đầu tới khi active/visible). Viết widget test: NativeAdWidget(active: false) trong tab ẩn của IndexedStack không gọi loadNative của adapter cho tới khi active chuyển true. Thêm log SafeLogger. Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho `active`/visibility trên `NativeAdWidget`, xác nhận không load khi ẩn/inactive; integration test qua `IndexedStack` thật.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, chuyển tab qua lại, xác nhận native ad không load ở tab ẩn (kiểm tra qua log/network).
8. Thành công: commit + push. Thất bại: quay lại bước 1.
