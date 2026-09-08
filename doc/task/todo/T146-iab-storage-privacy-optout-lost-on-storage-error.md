# T146 — Tín hiệu "đã từ chối quảng cáo cá nhân hoá" bị mất khi bộ nhớ tạm lỗi

**Loại:** bug (quyền riêng tư)
**Ưu tiên:** P0
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state (tự verify trực tiếp code), đối chiếu doc/audit round 31/32 (BLOCKER cũ, chỉ fix cho TCF chứ chưa fix cho CCPA/GPP)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Khi thiết bị người dùng gặp lỗi đọc bộ nhớ tạm (hiếm, ví dụ máy yếu/lag lúc đọc SharedPreferences), hệ thống đang coi đó là "chưa ai từ chối quảng cáo cá nhân hoá" — kể cả khi người dùng ĐÃ bấm từ chối trước đó. Hậu quả: một số quảng cáo cá nhân hoá vẫn hiện ra dù người dùng đã từ chối, vi phạm đúng điều họ yêu cầu (CCPA "Do Not Sell", GPP opt-out).

Đây CHÍNH XÁC là lớp lỗi BLOCKER round-31/32 từng tìm và fix, nhưng round đó chỉ fix cho nhánh `tcfAllowsPersonalisedAds()` — chưa bao giờ áp dụng fail-closed cho nhánh CCPA/US-Privacy/GPP.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/iab_storage.dart:185-269` — `read()`, `usPrivacyOptedOut()`, mọi `_gppXOptedOut()`: khi platform store lỗi (mở/đọc timeout/exception), trả về `null` — bị hệ thống hiểu là "chưa có tín hiệu" giống hệt "chưa từng ghi gì".
- So sánh: `tcfAllowsPersonalisedAds()` (dòng 482-545) đã fail-CLOSED đúng cách (đọc thẳng store, không qua `read()`, coi lỗi = không được phép cá nhân hoá).
- Điểm dùng thật: `_reconcileDeviceUsPrivacy()` (`ad_manager.dart:5701-5715`) chỉ hành động khi `optedOut == true` — nếu store lỗi đúng lúc user đã opt-out thật, tín hiệu `true` bị nuốt thành `null`, `doNotSell` không được áp cho AppLovin/AdMob.
- Chưa có test cho case "store hỏng" ở nhánh US-Privacy/GPP (chỉ có canary test cho TCF).

## Việc cần làm
1. Sửa `usPrivacyOptedOut()` và mọi `_gppXOptedOut()` trong `iab_storage.dart` để fail-CLOSED giống `tcfAllowsPersonalisedAds()`: khi store lỗi, coi như "đã từ chối" (an toàn hơn) thay vì "chưa từng nói gì".
2. Thêm log (SafeLogger) khi rơi vào nhánh fail-closed này (để dev biết đang xảy ra lỗi đọc storage thật, không phải bug logic).
3. Thêm demo rõ ràng trong `example/`: 1 trang debug mô phỏng "storage lỗi" (throw exception giả lập) và cho thấy app xử lý đúng (coi là đã opt-out) thay vì lộ quảng cáo cá nhân hoá.
4. Cập nhật CHANGELOG.md (mục version kế tiếp, ghi rõ đây là fix bảo mật/riêng tư) và README.md phần compliance nếu có nhắc tới cơ chế này.

## Prompt để chạy loop-fix
```
Sửa lỗi privacy fail-open trong packages/ad_sdk/lib/src/core/iab_storage.dart: usPrivacyOptedOut() và mọi _gppXOptedOut() (dòng ~185-269) hiện trả null khi platform store lỗi, bị hiểu nhầm thành "chưa từng có tín hiệu". Phải đổi sang fail-closed giống tcfAllowsPersonalisedAds() (dòng 482-545): lỗi đọc storage => coi như đã opt-out (an toàn hơn cho người dùng). Đọc kỹ ad_manager.dart:5701-5715 (_reconcileDeviceUsPrivacy) để hiểu đường đi thật của tín hiệu này trước khi sửa. Thêm log SafeLogger khi rơi vào nhánh fail-closed. Viết unit test mô phỏng storage throw exception cho cả US-Privacy và mọi tier GPP, xác nhận kết quả là "opted out" không phải null. Thêm demo trong example/ minh hoạ. Cập nhật CHANGELOG.md.
```

## Tín hiệu kết thúc loop (lặp lại đến khi đạt đủ)
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Có unit test cho mọi tier US-Privacy/GPP với storage lỗi (throw), xác nhận fail-closed đúng; có integration test end-to-end nếu khả thi.
3. Log SafeLogger đầy đủ ở nhánh mới.
4. Demo rõ ràng trong `example/` + CHANGELOG.md/README.md đã cập nhật.
5. Audit độc lập (dùng `codex exec --dangerously-bypass-approvals-and-sandbox`, `agy --dangerously-skip-permissions --print`, hoặc `claude --dangerously-skip-permissions -p` trên bản diff, hoặc tự audit nghiêm ngặt kiểu adversarial) — chấm điểm /10.
6. Nếu ≤9/10: liệt kê finding, sửa tiếp, quay lại bước 1.
7. Nếu >9/10: smoke test thật trên device/simulator (bật EEA/CCPA debug geography), ghi lại bằng chứng (log/screenshot) rằng quảng cáo cá nhân hoá KHÔNG hiện khi mô phỏng storage lỗi sau khi user đã từ chối.
8. Thành công bước 7: commit + push. Thất bại: quay lại bước 1.
