# T179 — Thêm test: server trả lỗi giữa lúc đang tải cấu hình an toàn từ xa

**Loại:** test-coverage
**Ưu tiên:** P2
**Trạng thái:** done
**Nguồn phát hiện:** subagent test-coverage-gap
**Quyết định chủ dự án (2026-09-08):** Thêm test ngay

## Vấn đề (giải thích thực tế)
Tính năng tải cấu hình an toàn từ server (`RemoteAdSafetyProvider`, có thể đổi giới hạn quảng cáo từ xa) chưa có test cho trường hợp server trả về lỗi đúng giữa lúc đang tải (không phải mất mạng hoàn toàn, mà lỗi nửa chừng — VD response 500, JSON hỏng giữa chừng). Round-40 đã phát hiện và fix 1 bug tương tự ở tầng demo app (double-tap race, missing catch/finally) nhưng chưa chắc `lib/src` có test tương đương cho provider ném exception giữa `initialize()`.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/config/remote_ad_safety_provider.dart` — có test hiện có (`remote_ad_safety_provider_test.dart`, `refresh_remote_safety_params_test.dart`) nhưng chưa rõ có test case provider throw exception giữa `initialize()` hay không.

## Việc cần làm
1. Đọc test hiện có, xác định có test case "throw giữa initialize()" chưa.
2. Nếu chưa: viết test mock provider throw đúng lúc `initialize()` đang chạy dở — xác nhận SDK không crash, fallback về giá trị an toàn mặc định (giống hành vi khi mất mạng hoàn toàn).
3. Nếu code hiện tại KHÔNG xử lý đúng (crash hoặc state rác), sửa để có try/catch/finally hợp lý, log rõ ràng.
4. Cập nhật CHANGELOG.md nếu có sửa code.

## Prompt để chạy loop-fix
```
Đọc packages/ad_sdk/lib/src/config/remote_ad_safety_provider.dart và test hiện có (remote_ad_safety_provider_test.dart, refresh_remote_safety_params_test.dart) để xác định đã có test case "provider throw exception giữa initialize()" (không phải mất mạng hoàn toàn, mà lỗi nửa chừng như response 500 hoặc JSON hỏng) chưa. Nếu chưa có, viết test mock throw đúng lúc initialize() đang await response — xác nhận SDK không crash và fallback về AdSafetyConfig mặc định an toàn, giống hệt hành vi khi mất mạng hoàn toàn. Nếu phát hiện code hiện tại xử lý sai (crash, state rác, hoặc không fallback đúng), sửa với try/catch/finally hợp lý + log SafeLogger rõ ràng.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho throw-giữa-initialize, xác nhận fallback đúng.
3. Nếu có sửa code: log SafeLogger + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: nếu có sửa code, smoke test thật qua `RemoteSafetyDemoPage` trong `example/`, mô phỏng lỗi server giữa chừng, xác nhận không crash.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-13) — chỉ xác nhận lại, không sửa code/test

Đọc kỹ `lib/src/core/ad_manager.dart` (2 nơi gọi
`remoteSafetyProvider.fetchSafetyParamOverrides()`: trong `initialize()`
và trong `refreshRemoteSafetyParams()`) và toàn bộ test hiện có, phát
hiện: **case "throw giữa initialize()" đã có test từ trước**, không phải
lỗ hổng thật như "nguồn phát hiện: subagent test-coverage-gap" nghĩ.

- `test/ad_manager_core_test.dart`, group `'remoteSafetyProvider (T88)'`,
  test `'a throwing provider falls back to local AdSafetyParams, does not
  block init'` — dùng `_ThrowingRemoteSafetyProvider` (throw `StateError`
  ngay trong `fetchSafetyParamOverrides()`), gọi thẳng qua tham số
  `remoteSafetyProvider:` của `AdManager().initialize()` thật (không
  phải mock riêng lẻ) — xác nhận `AdSafetyConfig` vẫn init đúng bằng giá
  trị local, không crash, không treo init.
- Cùng group có thêm test provider TREO (không bao giờ trả lời) — xác
  nhận timeout 5s fallback đúng, không phải chỉ throw ngay lập tức.
- Production code (`ad_manager.dart` quanh dòng 3046) đã bọc
  `try/catch` quanh `await remoteSafetyProvider.fetchSafetyParamOverrides()
  .timeout(Duration(seconds: 5))`, log `SafeLogger.w` rõ ràng khi lỗi,
  fallback về `effectiveSafety` (config local/ramp-adjusted) — đúng y
  hệt hành vi khi mất mạng hoàn toàn, đúng như task yêu cầu.
- Về "lỗi nửa chừng" (response 500, JSON hỏng) khác "mất mạng hoàn
  toàn": xét từ góc nhìn `AdManager`, `RemoteAdSafetyProvider` là
  interface do host tự implement — bất kể lý do thật (mất mạng, HTTP
  500, JSON parse lỗi) là gì, tất cả đều biểu hiện thành 1 `Future` bị
  reject (throw) ở phía `AdManager`. Test "provider throws" ĐÃ bao phủ
  đúng mức trừu tượng này — không cần giả lập HTTP request thật để chứng
  minh thêm gì, vì `AdManager` không bao giờ nhìn thấy tầng HTTP.
- Chạy lại 3 test trong group `remoteSafetyProvider (T88)`: **xanh cả
  3** (valid overrides / throwing provider / hanging provider).

Không có code nào cần sửa, không có test nào cần thêm. Đóng task ở dạng
xác nhận tài liệu (giống T204) — không có commit code, chỉ có việc di
chuyển file task.

Điểm tự chấm: **9.5/10** (không tạo giá trị code mới, nhưng xác nhận lại
đúng 1 gap nghi ngờ hoá ra không có thật — tránh việc viết test trùng lặp
không cần thiết).
