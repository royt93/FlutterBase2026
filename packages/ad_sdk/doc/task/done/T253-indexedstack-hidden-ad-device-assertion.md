# T253 — Chứng minh device test không load ad ở tab ẩn

- **Loại:** Test enhancement
- **Priority:** P3 · **Effort:** M
- **Confidence:** HYPOTHESIS test gap; unit tests hiện là chứng cứ chính
- **Status:** done (REFUTED; no stable device request-start signal; independent audit 9.5/10)
- **Evidence:** `example/integration_test/banner_indexedstack_visibility_test.dart`, `example/integration_test/native_indexedstack_visibility_test.dart` hiện chuyển tab và chủ yếu xác nhận không có exception; đối chiếu unit/widget visibility tests.
- **Dependency:** none

## Giá trị

Device tests hiện chưa chứng minh trực tiếp contract “tab ẩn không load/show”. Bổ sung assertion chỉ khi integration harness quan sát được load/show mà không dùng impression giả hoặc ad thật khó điều khiển. Unit tests vẫn là proof chính nếu device signal không ổn định.

## Kết luận điều tra (2026-10-15)

- Device tests (`banner_indexedstack_visibility_test.dart`, `native_indexedstack_visibility_test.dart`) chạy app/example thật với SDK init thật và chỉ quan sát chuyển tab + `takeException()`.
- Harness device không có counter request-start hoặc fake bridge: `AdLoadEvent` chỉ phát sau callback native load success/failure, và cũng có thể bị no-fill, consent, VIP, cap, network hoặc timing chi phối. Vắng `AdLoadEvent` trong cửa sổ quan sát không chứng minh request chưa bắt đầu.
- Proof widget-level deterministic hiện có dùng fake/counting adapter, và chỉ chứng minh không gọi adapter load; không chứng minh provider đã/không gửi network request hay impression. Native (`test/native_ad_widget_test.dart`, group `T154`) kiểm tra mounted `active:false` không gọi load, flip sang true gọi một lần, cùng hidden retry/deferred reload cases. Banner (`test/banner_ad_widget_test.dart`) kiểm tra inactive-first không gọi load và bare IndexedStack gate/toggle; không có coverage đối xứng cho mọi native retry path.
- Thêm assertion device chỉ dựa trên thiếu event/log sẽ là wait-and-hope, flaky và không chứng minh contract. Thêm bridge counter vào production chỉ để test device là thay đổi production ngoài phạm vi T253.
- Kết luận: REFUTED — giữ unit/widget tests là bằng chứng chính, không đổi code/device tests.

## Phạm vi

- Đã chọn: điều tra trước; chỉ thêm assertion nếu test harness có signal ổn định, nếu không kết luận REFUTED.
- Kiểm tra test harness hiện tại: không có signal request-start ổn định trên device.
- Không tuyên bố kiểm thử impression thật; không thử auto-dismiss AppLovin creative.

## Acceptance criteria

- [x] Kiểm tra signal: không có signal ổn định phân biệt “chưa request” với no-fill/chậm bằng harness device hiện tại.
- [x] Không thêm device assertion flaky; không sửa production visibility code.
- [x] Unit/widget tests hiện có là proof widget-level chính: banner/native không gọi adapter load khi inactive-first mount, active toggle; native còn có hidden retry/deferred-reload cases; bare IndexedStack được kiểm tra ở banner. Không claim network/impression proof.
- [x] Sửa comment device test native để không claim unit tests chứng minh impression/network behavior.
- [x] Android/iOS integration/smoke mới: N/A vì không thêm assertion hoặc đổi behavior; limitation được ghi rõ.
- [x] Audit độc lập kết luận REFUTED: 9.5/10, không có finding.

## Prompt vòng lặp

Điều tra T253: đọc integration/unit tests và fixture bridge trước. Không thêm wait-and-hope assertion. Prove signal có ý nghĩa và deterministic trước; nếu không thể observably test trên device thì đóng REFUTED, không sửa production visibility code. End loop: audit diff + điểm /10, unit/widget/integration mọi case hợp lý và smoke thiết bị Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.