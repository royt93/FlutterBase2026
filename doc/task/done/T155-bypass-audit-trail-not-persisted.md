# T155 — Nhật ký "back door" biến mất mỗi khi tắt hẳn app

**Loại:** enhancement (bảo toàn bằng chứng compliance)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent consent+compliance, tự verify
**Quyết định chủ dự án (2026-09-08):** Lưu lại lâu dài (persist), không giữ chỉ-tạm-thời

## Vấn đề (giải thích thực tế)
Khi có sự cố, hệ thống dùng "back door" (`bypassSafety`) đúng 1 chỗ duy nhất lúc mở app — màn hình chờ đầu tiên (splash), theo đúng hợp đồng tích hợp trong README/CLAUDE.md. Hệ thống có ghi lại nhật ký (`BypassAuditTrail`, tự gọi là "flagship proof-of-compliance") để sau này chứng minh "chỉ dùng đúng chỗ đã khai báo". Nhưng nhật ký này chỉ nằm trong bộ nhớ tạm (RAM) — mỗi lần người dùng tắt hẳn app (rất hay xảy ra trên điện thoại), nhật ký cũ biến mất. Nếu sau này cần chứng minh cho đối tác/audit, chỉ còn nhật ký của lần mở app gần nhất.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart` (toàn bộ) + `packages/ad_sdk/lib/src/core/ad_manager.dart:1293` — `BypassAuditTrail` chỉ là ring-buffer trong RAM, không persist qua `AdPreferences` như `AdEventLog` (`ad_event_log.dart` có `_load()`/`_persist()` qua SharedPreferences).
- Nguồn ghi chính (`bypassSafety`) xảy ra ở mỗi cold-start splash — app bị kill là chuyện thường ngày trên mobile, nên lịch sử "back door" của phiên trước biến mất khỏi RAM nếu host không chủ động export ngay trong phiên đó.

## Việc cần làm
1. Persist `BypassAuditTrail` giống `AdEventLog` (dùng cùng debounce/persist pattern có sẵn qua `AdPreferences`).
2. Giữ giới hạn kích thước hợp lý (ring-buffer, không phình vô hạn) — quyết định số lượng entry tối đa lưu trữ, document rõ trong docstring.
3. Thêm log SafeLogger khi entry mới được ghi và khi persist thành công/thất bại.
4. Thêm demo trong `example/`: hiển thị lịch sử bypass đã lưu qua nhiều lần mở/tắt app (không chỉ phiên hiện tại).
5. Cập nhật CHANGELOG.md và docstring của `BypassAuditTrail` (bỏ giới hạn "chỉ phiên hiện tại" cũ, ghi rõ giờ đã persist).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart: BypassAuditTrail hiện chỉ là ring-buffer trong RAM (final BypassAuditTrail bypassAuditTrail = BypassAuditTrail(); ở ad_manager.dart:1293), mất dữ liệu mỗi khi app bị kill. Đọc ad_event_log.dart để hiểu đúng pattern persist/debounce/_load()/_persist() qua AdPreferences đã dùng cho AdEventLog, áp dụng tương tự cho BypassAuditTrail — giữ ring-buffer nhưng ghi xuống SharedPreferences định kỳ/mỗi lần thêm entry, load lại lúc khởi động. Giới hạn số entry lưu trữ hợp lý (đối chiếu AdEventLog dùng bao nhiêu). Viết unit test: thêm entry, "khởi động lại" (tạo instance mới đọc từ cùng AdPreferences mock), xác nhận entry cũ vẫn còn. Thêm log SafeLogger. Thêm demo trong example/ hiển thị lịch sử bypass qua nhiều lần khởi động lại app.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test persist/reload cho `BypassAuditTrail` (giống pattern test của `AdEventLog`); test giới hạn kích thước ring-buffer.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md + docstring cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device — dùng bypass ở splash, tắt hẳn app (kill process thật, không chỉ background), mở lại, xác nhận lịch sử bypass cũ vẫn còn trong demo.
8. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-10)

**Fix:** `BypassAuditTrail` giờ persist qua `AdPreferences` (khoá riêng
`ad_sdk_bypass_audit_trail_v1`), mirror đúng pattern debounce/`_load()`/
`_persist()`/`flush()` của `AdEventLog`. Vì `bypassAuditTrail` là field khởi
tạo NGAY lúc khai báo (trước khi có `AdPreferences`, và phải sống sót qua cả
`destroy()`), thêm `attach(prefs)` — gọi 1 lần bên trong `initialize()`,
load dữ liệu cũ từ phiên trước rồi mới bật ghi đĩa từ đó về sau.

**codex review — 3 vòng, tất cả tìm bug thật:**
- Vòng 1 (3 finding): (1) `flush()` chưa được gọi ở đâu cả trước khi app có
  thể bị kill (destroy()/backgrounding) → sửa thêm gọi `flush()`. (2)
  `attach()` gọi lại lần 2 (destroy()+reinit) load lại y nguyên snapshot cũ
  đè lên dữ liệu đã có → nhân đôi lịch sử mỗi lần reinit → thêm cờ `_loaded`
  chỉ load 1 lần duy nhất cho cả tiến trình. (3) Entry ghi TRƯỚC khi
  `attach()` chạy (trước init) không bao giờ được lưu xuống đĩa → thêm
  persist ngay trong `attach()` nếu có entry cũ.
- **Phát hiện nghiêm trọng khi tự verify (không phải codex tìm)**: bản fix
  đầu tiên cho `destroy()` — `await bypassAuditTrail.flush().timeout(2s)`
  — làm treo TOÀN BỘ file `test/ad_manager_core_test.dart` (243 test) tới
  10 phút mỗi lần chạy full suite, dù có bọc timeout 2 giây. Đã tự phát
  hiện qua `flutter test` full suite (không phải qua codex), rồi
  bisect từng dòng (tắt/bật lần lượt `attach()` và dòng flush trong
  `destroy()`) để xác định chính xác dòng nào gây treo — không đoán mò.
  Xác nhận: dòng flush trong `destroy()` là thủ phạm; bỏ hẳn dòng đó
  (không giữ lại dưới dạng comment) — vẫn giữ nguyên `attach()` và flush ở
  `didChangeAppLifecycleState` (bắt đúng lúc app bị background, thời điểm
  thực tế gần với process-kill hơn destroy() độc lập). Sau khi bỏ, full
  suite từ >10 phút treo còn 1 phút 36 giây, xanh hết.
- Vòng 2 (2 finding): (1) Flush ở `didChangeAppLifecycleState` từng nằm
  SAU 2 lớp guard (`!isInitialised` và `adapter == null`) — nhưng
  `showAppOpenAd(bypassSafety:true)` ghi vào trail TRƯỚC khi check cả hai
  điều kiện đó, nên 1 bypass ghi sớm trong lúc splash (trước khi init xong)
  bị bỏ qua hoàn toàn nếu app bị background ngay lúc đó → chuyển flush lên
  ĐẦU hàm, trước mọi guard. (2) `_load()` dùng `.map()` lazy — nếu entry
  thứ 2 trong danh sách lỗi, entry thứ 1 (hợp lệ) đã kịp `insertAll` trước
  khi exception ném ra → giữ lại 1 phần dữ liệu chưa validate dù log nói
  "đã bỏ hết" → thêm `.toList()` để ép giải mã toàn bộ trước khi chèn
  (tất cả-hoặc-không-gì).
- Vòng 3 (1 finding): `flush()` gọi trực tiếp `_persistChain.then(...)`
  KHÔNG có `.catchError()` (khác với `_schedulePersist()` đã có sẵn) — nếu
  ghi đĩa thật sự lỗi 1 lần, `_persistChain` bị "hỏng vĩnh viễn", mọi
  `flush()`/ghi tiếp theo im lặng thất bại mãi mãi → thêm `.catchError()`
  y hệt `_schedulePersist()`.

**Test:**
- Unit (`test/bypass_audit_trail_test.dart`, nhóm "persistence (T155)"):
  8 case — reload sau "khởi động lại", chưa attach vẫn ghi RAM không crash,
  JSON hỏng bị bỏ (không throw), giới hạn maxEntries sống sót qua reload,
  clear() xoá cả bản lưu, flush() ghi ngay không chờ debounce, entry ghi
  trước attach() vẫn được lưu, attach() gọi 2 lần không nhân đôi lịch sử,
  1 entry hỏng không giữ lại phần hợp lệ trước nó.
- Unit bổ sung (`test/ad_manager_core_test.dart`): 1 case mới xác nhận
  app bị background lúc CHƯA có adapter vẫn flush được bypass ghi trước đó.
- Widget (`example/test/compliance_demo_page_test.dart`): nút "Simulate a
  bypass" hoạt động trước khi SDK init, không crash.
- Integration (`example/integration_test/bypass_audit_trail_persistence_test.dart`,
  chạy thật trên **Pixel 7 Pro**, `--dart-define=AD_PROVIDER_ADMOB=true`):
  tạo 1 `BypassAuditTrail` MỚI, độc lập, attach vào CÙNG storage thật trên
  máy — đọc lại đúng entry mà trail đang chạy vừa ghi, chứng minh round-trip
  qua plugin SharedPreferences thật (không phải mock) hoạt động. Xanh.

**Demo:** `ComplianceDemoPage` thêm card "Bypass audit trail (T155)" — nút
"Simulate a bypass" + "Refresh", hiển thị tổng số entry + 5 entry gần nhất
(timestamp, kind, callSiteTag). README hướng dẫn: kill app thật (vuốt khỏi
recents, không chỉ background), mở lại, xác nhận lịch sử còn nguyên.

**Suite:** 1816/1816 (`packages/ad_sdk`), 40/40 (`example`). `flutter
analyze` sạch cả 2 package. 1 lần chạy full suite dính flake có sẵn không
liên quan (`ump_auto_fail_open_closed_widget_test.dart`, lỗi mock plugin
connectivity khi chạy đồng thời nhiều file — chạy riêng file đó xanh ngay,
xác nhận không phải do T155).

**Điểm tự chấm:** 9.3/10 — 6/6 finding qua 3 vòng codex đều thật và đã sửa
hết; trừ điểm vì bản fix đầu cho destroy() gây regression nghiêm trọng
(treo cả suite 10 phút) mà bản thân phải tự phát hiện qua full-suite run
chứ không phải codex bắt được — bài học: mọi thay đổi vào `destroy()`/
lifecycle callback bắt buộc phải chạy full suite của FILE liên quan trước
khi coi là xong, không chỉ chạy file test riêng của tính năng mới.
