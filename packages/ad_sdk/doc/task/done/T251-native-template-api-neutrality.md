# T251 — Tách template sizing khỏi API Google trong NativeAdWidget

- **Loại:** Enhancement / API design
- **Priority:** P3 · **Effort:** M
- **Confidence:** CONFIRMED provider asymmetry; product impact needs validation
- **Status:** done (REFUTED; API unchanged; README/class doc clarified; independent audit 9.5/10)
- **Evidence:** `lib/src/widget/native_ad_widget.dart` (`templateType` dùng `google_mobile_ads.TemplateType`, AppLovin path không sử dụng); `README.md` phần native-ad customization; `test/native_ad_widget_test.dart`
- **Dependencies:** SemVer policy; `test/api_golden_test.dart`; `CHANGELOG.md`

## Giá trị

Public widget provider-neutral nhưng nhận `google_mobile_ads.TemplateType`; AppLovin không dùng thuộc tính này. Host tích hợp đa provider phải hiểu kiểu Google dù chọn AppLovin. Đánh giá API trung lập thực sự, chỉ khi có lợi ích tương thích rõ; không biến mọi chi tiết provider thành abstraction.

## Kết luận nghiên cứu (2026-10-15)

- AdMob `templateType` chọn `TemplateType.small`/`medium`, thay đổi template Google render và mặc định `height` (90/320 logical px). `factoryId` chọn NativeAdFactory host-registered.
- AppLovin `MaxNativeAdView` là layout tự vẽ; adapter bỏ qua `templateType` cho nội dung render và bỏ qua `factoryId`. Tuy vậy widget vẫn dùng `templateType` để tính default `height` (small=90, medium=320) trên cả provider. `height` override dùng chung; `customNativeAdBuilder` riêng cho AppLovin.
- Không tồn tại semantics template tương ứng ở AppLovin. Mapping enum riêng của SDK sang chiều cao hoặc sang custom builder sẽ tạo abstraction gây hiểu nhầm.
- Owner chọn giữ API, không thay đổi code; README phân biệt `templateType` chọn rendered template chỉ cho AdMob nhưng vẫn chọn default widget height cho cả hai; `height` override dùng chung.
- Kết luận: REFUTED — không đổi public API, không thêm enum/alias/deprecation. Không cần SemVer/API golden/changelog hay runtime tests cho T251.

## Phạm vi đã nghiên cứu

- So sánh semantics `NativeAdWidget`, `AdMobAdapter.preloadNative`, `AppLovinAdapter.preloadNative`, tests và README.
- Không tạo mapping giả cho AppLovin; không đổi public API hoặc behavior.

## Acceptance criteria

- [x] Bằng chứng ghi rõ template sizes/semantics AdMob và ignored/custom-layout behavior AppLovin, cùng tests/docs.
- [x] Quyết định: REFUTED — giữ API hiện tại, không thêm abstraction/mapping không có semantics tương đương.
- [x] README phân biệt `templateType` chọn rendered template AdMob, nhưng cũng điều khiển default widget height (small=90/medium=320) cho cả provider; `height` override áp dụng cả hai.
- [x] Widget/integration/smoke tests không áp dụng — wording-only, không đổi code hay behavior.
- [x] API golden/changelog không áp dụng — public signature và behavior không đổi.
- [x] README và class doc về default height/provider asymmetry nhất quán; chỉ đổi 3 dòng doc-comment trong code; `git diff --check` và analyzer sạch.
- [x] Fresh independent review của wording cuối: 9.5/10, không còn finding.

## Prompt vòng lặp

Điều tra T251 trước khi thay API. Đọc NativeAdWidget, cả adapter/provider docs, API stability policy và tests. Không thêm enum nếu không biểu đạt cùng semantics ở cả hai provider. Nếu đổi, viết test tương thích/rebuild trước, cập nhật golden/changelog và migration notes. End loop: audit diff + điểm /10, unit + widget + integration mọi đường hỗ trợ, smoke thiết bị Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.