# T251 — Tách template sizing khỏi API Google trong NativeAdWidget

- **Loại:** Enhancement / API design
- **Priority:** P3 · **Effort:** M
- **Confidence:** CONFIRMED provider asymmetry; product impact needs validation
- **Status:** todo
- **Evidence:** `lib/src/widget/native_ad_widget.dart` (`templateType` dùng `google_mobile_ads.TemplateType`, AppLovin path không sử dụng); `README.md` phần native-ad customization; `test/native_ad_widget_test.dart`
- **Dependencies:** SemVer policy; `test/api_golden_test.dart`; `CHANGELOG.md`

## Giá trị

Public widget provider-neutral nhưng nhận `google_mobile_ads.TemplateType`; AppLovin không dùng thuộc tính này. Host tích hợp đa provider phải hiểu kiểu Google dù chọn AppLovin. Đánh giá API trung lập thực sự, chỉ khi có lợi ích tương thích rõ; không biến mọi chi tiết provider thành abstraction.

## Phạm vi

- So sánh kích thước template native hiện có trên cả hai adapter và host custom factory/layout.
- Nếu cần API chung, dùng package-owned enum/contract; giữ đường migration SemVer tương thích, cập nhật barrel/golden/docs.
- Nếu không có template semantics tương ứng ở AppLovin thì giữ provider-specific option hoặc kết luận không đổi; không tạo mapping giả.

## Acceptance criteria

- [ ] Bằng chứng mô tả semantics native template trên AdMob và AppLovin, cùng call sites/docs.
- [ ] Có quyết định API: đổi, bổ sung tương thích hay REFUTED; không phá vỡ API public ngoài policy.
- [ ] Nếu code thay đổi: widget tests cho AdMob template variants, AppLovin ignored/custom path và rebuild/config changes.
- [ ] Integration test Android/iOS qua bridge/plugin thực tế cho các đường được hỗ trợ; không yêu cầu creative dismissal tự động.
- [ ] Smoke test Android/iOS cho native layout thật/test ad, ghi rõ provider/platform được xác minh.
- [ ] Unit/widget/integration, analyze, API golden, changelog đầy đủ; audit độc lập >9/10.

## Prompt vòng lặp

Điều tra T251 trước khi thay API. Đọc NativeAdWidget, cả adapter/provider docs, API stability policy và tests. Không thêm enum nếu không biểu đạt cùng semantics ở cả hai provider. Nếu đổi, viết test tương thích/rebuild trước, cập nhật golden/changelog và migration notes. End loop: audit diff + điểm /10, unit + widget + integration mọi đường hỗ trợ, smoke thiết bị Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.