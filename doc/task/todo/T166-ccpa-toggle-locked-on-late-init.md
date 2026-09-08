# T166 — Công tắc từ chối bán dữ liệu (CCPA) bị khoá cứng nếu mở màn hình quá sớm

**Loại:** bug (quyền riêng tư)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent consent+compliance, tự verify
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Có 1 công tắc cho phép người dùng California/Mỹ từ chối bán dữ liệu (CCPA). Nếu màn hình này mở ra đúng lúc SDK chưa khởi động xong (vài giây đầu mở app), công tắc bị khoá cứng (màu xám) vĩnh viễn cho đến khi người dùng rời khỏi màn hình và quay lại — dù SDK đã khởi động xong ngay sau đó, công tắc vẫn không tự sáng lại.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/consent/ccpa_opt_out_toggle.dart:44-48` — `_CcpaOptOutToggleState.initState()` chỉ đọc `AdManager().consentManager?.listenable` MỘT LẦN; nếu widget mount trước khi `AdManager().initialize()` xong (`consentManager` còn null), không có `didUpdateWidget`/listener nào khác để phản ứng khi SDK init xong sau đó.
- SDK đã có sẵn đúng pattern để giải quyết việc này: `vipReady` (`ad_manager.dart:475`, `ValueListenable<bool>`) và `SimpleEventBus`/`BoolEvent` (replay sự kiện cho listener đăng ký muộn, dòng 3438/3927/3967) — nhưng `CcpaOptOutToggle` không dùng pattern này.

## Việc cần làm
1. Sửa `CcpaOptOutToggle` để lắng nghe sự kiện "SDK init hoàn tất" (dùng pattern `SimpleEventBus`/`BoolEvent` có sẵn, hoặc theo dõi 1 `ValueListenable` tương tự `vipReady`), tự cập nhật `consentManager?.listenable` khi có.
2. Thêm test: mount widget trước khi init xong, sau đó init hoàn tất trong lúc widget vẫn sống — xác nhận công tắc tự sáng lại đúng trạng thái, không cần rời màn hình.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/consent/ccpa_opt_out_toggle.dart dòng ~44-48: _CcpaOptOutToggleState.initState() chỉ đọc AdManager().consentManager?.listenable một lần — nếu widget mount trước khi AdManager().initialize() xong, listenable là null mãi mãi cho tới khi widget bị dispose và mount lại. Đọc ad_manager.dart để tìm pattern đã dùng cho vipReady (dòng ~475, ValueListenable<bool>) hoặc SimpleEventBus/BoolEvent (dòng ~3438,3927,3967, có replay cho listener đăng ký muộn) — áp dụng pattern tương tự để CcpaOptOutToggle tự phát hiện khi consentManager trở nên non-null sau init. Cập nhật test/ccpa_opt_out_toggle_test.dart (hiện chỉ test "disabled lúc đầu" ở dòng ~106-115): thêm case mount trước khi init xong, rồi init hoàn tất trong lúc widget vẫn sống trong tree, xác nhận công tắc tự cập nhật đúng trạng thái thật.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho case mount-trước-init-xong, xác nhận tự cập nhật không cần rời màn hình.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, mở màn hình CCPA ngay lúc mới mở app (trước khi splash xong), xác nhận công tắc tự sáng lại đúng khi SDK init xong.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
