# T252 — Sửa mô tả route lifecycle của NativeAdWidget

- **Loại:** Fix documentation
- **Priority:** P2 · **Effort:** XS
- **Confidence:** CONFIRMED docs contradiction
- **Status:** done (README corrected; documentation diff clean; independent audit 9.5/10, no findings)
- **Evidence:** `README.md` phần NativeAdWidget; `lib/src/widget/native_ad_widget.dart` ghi rõ widget không dùng RouteAware; đối chiếu `CLAUDE.md` integration caveats
- **Dependency:** none

## Giá trị

README có câu mô tả NativeAdWidget dùng route-aware gating giống MREC, nhưng phần cùng mục và implementation nói widget không có route-pause. Người tích hợp có thể giả định route cover tự pause native ads. Sửa câu mở đầu và đưa caveat `active`/hidden tab vào vị trí dễ thấy.

## Acceptance criteria

- [x] Sửa README trực tiếp, không chỉ thêm known-limitation note.
- [x] README nói rõ NativeAdWidget không tự pause khi route bị cover.
- [x] Nêu rõ host phải đặt `active: false/true` cho retained hidden tabs/children; phân biệt khỏi Banner/MREC tự pause route và tự quản lý scroll visibility.
- [x] Nội dung khớp class doc, `initState`/`didUpdateWidget` và tests hiện tại; không thêm claim behavior mới.
- [x] Docs/link check: wording-only, không thêm link; diff check clean. Unit/widget/integration/device tests không áp dụng vì không đổi behavior.

## Prompt vòng lặp

Sửa T252 tối thiểu. Đối chiếu README với NativeAdWidget implementation, CLAUDE.md và tests; sửa mâu thuẫn, không đổi code. End loop: audit nội dung và chấm /10, chạy kiểm tra tài liệu phù hợp. Unit/widget/integration/smoke device không áp dụng vì không có behavior change. Chỉ chuyển done khi điểm >9/10; không commit/push nếu chưa được người dùng xác nhận.