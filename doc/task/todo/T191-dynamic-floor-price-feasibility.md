# T191 — Tự đặt "giá tối thiểu" cho quảng cáo (NGHIÊN CỨU KHẢ THI, CHƯA CHẮC LÀM ĐƯỢC)

**Loại:** exclusive-feature (idea, khả thi chưa rõ)
**Ưu tiên:** P3 (chỉ nghiên cứu)
**Trạng thái:** todo (research-only, KHÔNG code)
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Chỉ tìm hiểu khả thi trước (KHÔNG hứa làm)

## Ý tưởng
Tự đặt "giá tối thiểu" cho mỗi quảng cáo (không bán rẻ hơn giá này — dynamic floor price / bid targeting). Vấn đề: việc này thường phải làm trên trang quản lý web của Google/AppLovin (không phải trong code chạy trên điện thoại), nên nhiều khả năng SDK này KHÔNG TỰ LÀM ĐƯỢC ý này ở tầng Flutter wrapper.

## Việc cần làm (CHỈ nghiên cứu — KHÔNG code)
1. Tìm hiểu API chính thức của `google_mobile_ads` và `applovin_max` (package Dart đang dùng) — có API nào cho phép set floor price / targeting theo request không? Đọc kỹ tài liệu chính thức, không đoán.
2. Tìm hiểu cơ chế mediation waterfall thật của AdMob Mediation/AppLovin MAX — floor price thường được cấu hình ở cấp "ad unit"/"waterfall" trên dashboard, không phải per-request từ client. Xác nhận đúng/sai giả định này.
3. Nếu có API client-side nào cho phép ảnh hưởng (dù gián tiếp, VD custom targeting keywords/extras gửi kèm request), ghi rõ khả năng và giới hạn của nó.
4. Kết luận rõ ràng: khả thi hoàn toàn / khả thi một phần (nêu rõ phần nào) / không khả thi ở tầng SDK này.

## Prompt để chạy (giai đoạn nghiên cứu)
```
Nghiên cứu: package google_mobile_ads và applovin_max (bản đang pin trong packages/ad_sdk/pubspec.yaml) có API nào cho phép SDK client-side đặt "floor price"/giá sàn hoặc ảnh hưởng bid targeting theo từng request quảng cáo không? Đọc tài liệu chính thức, changelog, và source code của 2 package này (không đoán, không suy diễn). Xác nhận: floor price trong mediation waterfall của AdMob Mediation/AppLovin MAX có thực sự chỉ cấu hình được trên dashboard web (Ad Manager/AppLovin dashboard) hay có API client-side nào không. Nếu có API custom targeting/extras gửi kèm request (dù không trực tiếp là "floor price"), ghi rõ khả năng thực tế và giới hạn. Viết kết luận rõ ràng vào file task T191 này, KHÔNG viết code, KHÔNG hứa hẹn tính năng nếu chưa xác nhận chắc chắn khả thi.
```

## Tín hiệu kết thúc (KHÔNG code, KHÔNG push code)
Dừng khi đã điền đầy đủ mục "Kết luận nghiên cứu" bên dưới với: khả thi/không khả thi + bằng chứng cụ thể (trích dẫn tài liệu/API). Nếu kết luận là "khả thi một phần" hoặc "khả thi", chuyển thành 1 task mới (số ID kế tiếp) với đầy đủ template loop-fix chuẩn trước khi bắt đầu code — không code trực tiếp trong file nghiên cứu này.

## Kết luận nghiên cứu
(để trống, điền sau khi nghiên cứu xong)
