# T184 — Lưu tạm trạng thái quảng cáo trong bộ nhớ mã hoá để mở lại app nhanh hơn

**Loại:** idea (thử nghiệm, chấp nhận làm)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Làm (lưu ý: phải có cơ chế lưu định kỳ xuống đĩa để bù lại rủi ro mất dữ liệu khi app bị tắt đột ngột — đã nêu rõ trong lúc hỏi ý kiến)

## ⚠️ TẠM DỪNG — cần chủ dự án xác nhận lại (2026-09-13)

Đã đọc kỹ `ad_manager.dart` (`didChangeAppLifecycleState`, dòng ~8226+)
trước khi code. Phát hiện: lúc app từ background quay lại foreground
(KHÔNG bị OS kill process), toàn bộ state quảng cáo (slot, VIP, consent)
đã nằm sẵn trong RAM — process sống xuyên suốt, KHÔNG có bước đọc đĩa
nào xảy ra lúc resume cả. Chỉ khi OS kill hẳn process (RAM mất, key
AES-GCM cũng mất theo đúng thiết kế) thì mới cần đọc lại — nhưng đó là
**cold start** (app mở lại từ đầu), không phải "resume", và GAID/
consent/VIP đã có cơ chế lưu trữ riêng của chúng rồi.

Nói cách khác: snapshot mã hoá trong RAM như mô tả ban đầu KHÔNG tăng
tốc độ resume ở bất kỳ trường hợp nào — vì không có I/O nào để loại bỏ
lúc resume thật. Task tạm dừng ở đây, CHƯA code, chờ chủ dự án xác nhận
lại: có ngữ cảnh/mục tiêu nào khác chưa nêu rõ ban đầu không (VD thực ra
muốn tối ưu cold-start thay vì resume), hay huỷ task này.

## Ý tưởng
Thay vì lưu trạng thái phiên quảng cáo xuống đĩa mỗi lần, giữ tạm trong bộ nhớ mã hoá (AES-GCM, key tạo tạm mỗi phiên trong RAM) để mở lại app nhanh hơn (ít đợi chờ đĩa — loại bỏ độ trễ I/O khi chuyển background/foreground).

## Rủi ro đã xác nhận với chủ dự án
Nếu hệ điều hành tắt hẳn app đột ngột (hay xảy ra khi chạy nền lâu), dữ liệu snapshot chưa kịp lưu xuống đĩa có thể mất. **Chủ dự án đã đồng ý chấp nhận rủi ro này NHƯNG yêu cầu bắt buộc có cơ chế ghi định kỳ (periodic write-through) xuống storage để giảm thiểu mất mát** — không được chỉ giữ trong RAM thuần không có bù đắp nào.

## Việc cần làm
1. Thiết kế snapshot: trạng thái phiên quảng cáo nào thực sự cần cache nhanh (không phải toàn bộ state — chỉ phần đọc/ghi thường xuyên lúc resume, VD trạng thái slot hiện tại, không phải VIP/consent vốn đã có cơ chế riêng).
2. Mã hoá AES-GCM với key tạo mỗi phiên (không lưu key xuống đĩa — key sống trong RAM, mất theo phiên).
3. Thêm cơ chế ghi định kỳ xuống `AdPreferences`/SharedPreferences (VD mỗi N giây hoặc mỗi lần thay đổi quan trọng) để bù lại rủi ro mất dữ liệu khi bị kill.
4. Viết test: resume nhanh hơn có thể đo được (so sánh thời gian trước/sau); mô phỏng "app bị kill" giữa 2 lần ghi định kỳ, xác nhận dữ liệu chỉ mất tối đa khoảng thời gian giữa 2 lần ghi (không mất toàn bộ).
5. Thêm demo trong `example/` đo thời gian resume trước/sau.
6. Cập nhật CHANGELOG.md và README.md (giải thích cơ chế mới, giới hạn dữ liệu có thể mất tối đa bao lâu).

## Prompt để chạy loop-fix
```
Thiết kế và implement cơ chế lưu tạm trạng thái phiên quảng cáo trong bộ nhớ mã hoá (AES-GCM, key tạo mỗi phiên, không lưu key xuống đĩa) để giảm độ trễ I/O khi resume app, ĐỒNG THỜI bắt buộc có cơ chế ghi định kỳ (periodic write-through) xuống AdPreferences/SharedPreferences để giảm thiểu mất dữ liệu nếu app bị OS kill đột ngột — đây là yêu cầu bắt buộc từ chủ dự án, không được bỏ qua. Xác định rõ phạm vi state nào cần cache nhanh (không phải toàn bộ SDK state, chỉ phần đọc/ghi thường xuyên lúc resume). Viết test: đo thời gian resume trước/sau (nếu có benchmark harness sẵn, dùng lại; nếu không, đo bằng timestamp trong integration test); mô phỏng kill giữa 2 lần ghi định kỳ, xác nhận mất dữ liệu tối đa đúng bằng khoảng ghi định kỳ, không mất toàn bộ phiên. Thêm demo đo thời gian resume trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho mã hoá/giải mã snapshot; test ghi định kỳ; test mô phỏng kill giữa 2 lần ghi (mất dữ liệu có giới hạn, không mất toàn bộ).
3. Demo đo thời gian resume trong `example/` + CHANGELOG.md/README.md cập nhật (ghi rõ giới hạn mất dữ liệu tối đa).
4. Audit độc lập (đặc biệt kiểm tra kỹ: key AES-GCM không bị lưu/leak xuống đĩa hay log) — chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, đo thời gian resume trước/sau bằng số liệu thật; test kill app (force-stop) giữa chừng, mở lại, xác nhận dữ liệu chỉ mất trong giới hạn đã thiết kế.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Xác nhận lại với chủ dự án (2026-09-15) — mục tiêu thật là cold start

Hỏi lại qua AskUserQuestion: mục tiêu thật không phải "resume" (đã xác
nhận không có I/O nào ở kịch bản này) mà là **cold start** (mở app lại
sau khi bị OS kill hẳn process).

### Điều tra cold start thật (đọc kỹ `AdManager.initialize()`)

Chuỗi await tuần tự trong `initialize()`
(`lib/src/core/ad_manager.dart:2995-3900+`):
- `AdPreferences.getInstance()` (SharedPreferences) — dòng 3173.
- (tuỳ chọn) `remoteSafetyProvider.fetchSafetyParamOverrides()` — bounded 5s.
- `AdSafetyConfig.init(prefs, ...)` — dòng 3215.
- iOS: `AppTrackingTransparency.trackingAuthorizationStatus` — bounded 5s.
- `_resolveDeviceGaid()` — platform channel GAID.
- `vip.load(currentDeviceGaid: ...)` — đọc flutter_secure_storage, **phụ
  thuộc thật** vào GAID vừa resolve ở bước trên (không song song hoá
  được với bước đó).
- `FirstInstallGuard.hasAlreadyGranted()` — đọc iOS Keychain, bounded 5s.
- `ConsentManager.bootstrap()` — đọc SharedPreferences.
- UMP consent flow: **KHÔNG await** — đã là fire-and-forget có chủ đích
  từ trước (comment trong code giải thích: awaiting form user từng gây
  "20s startup freeze" thật, đã fix).
- `adapter.initialize(config, ...)` — **native AdMob/AppLovin SDK init
  qua platform channel, bounded 20s timeout** — bước NẶNG NHẤT, bắt buộc
  chạy SAU khi biết consent (comment trong code giải thích rõ lý do),
  không song song hoá được.

**Kết luận:** chi phí thật sự áp đảo cold start là `adapter.initialize()`
(native SDK init, tới 20s) — **nằm ngoài khả năng kiểm soát của SDK
Flutter này**, không cache/snapshot RAM/đĩa nào giúp được. Các bước I/O
cục bộ (SharedPreferences/secure storage) vốn đã nhanh (đơn vị mili giây
trên thiết bị hiện đại) — dù có song song hoá được cũng chỉ tiết kiệm vài
chục ms, không đáng kể so với native init. `AdConfig.splashMaxDuration`
(mặc định 8s) đã cap worst-case UX độc lập với timeout nội bộ của
`initialize()`.

**Cả 2 cách hiểu task (resume lẫn cold start) đều không có vấn đề thật để
giải quyết ở tầng SDK Flutter này.**

## Đóng task (2026-09-15)

Chủ dự án xác nhận qua AskUserQuestion: **huỷ, đóng lại**. Không
triển khai snapshot mã hoá RAM dưới bất kỳ cách hiểu nào của task gốc —
lý do kỹ thuật đã ghi đầy đủ ở trên (2 vòng điều tra, cả 2 đều xác nhận
không có bottleneck thật để giải quyết ở tầng này).
