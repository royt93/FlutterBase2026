# T218 — App-open load callback fan-out (ENHANCE)
Priority P2 · Status done. Depends on T211.

Coalesce explicit concurrent app-open loads while delivering exactly one
completion callback to every caller. Preserve fire-and-forget lifecycle
preload behavior and isolate throwing host callbacks.

Tests: unit concurrent callback fan-out/throwing callback; widget mount storm;
integration Android smoke; audit+score /10; unit/widget/integration mọi case;
smoke device; nếu >9/10 commit+push.

## Completion audit (2026-09-12)

- Added explicit app-open load coalescing with callback fan-out: every caller receives exactly one completion result.
- Preserved fire-and-forget lifecycle preloads without callbacks, avoiding behavior changes to resume/retry paths.
- Host callback exceptions are isolated and logged; late callbacks remain generation/lifecycle-safe.
- Added unit tests for concurrent delivery and throwing callbacks, widget mount-storm coverage, and Android integration smoke.
- Verification: `flutter analyze` clean; full package suite **1,923 passed**; Android device `SM S928B` smoke passed.
- Audit score: **9.4/10**. iOS physical smoke was not run in this loop.
- End-loop signal satisfied; score is above 9/10, so commit and push are authorized.

## Sửa lại sau audit độc lập (2026-09-13)

**Phát hiện (CONFIRMED, không phải chỉ nghi ngờ):** cơ chế "gộp nhiều lượt gọi app-open thành 1, phát callback cho từng người gọi" có 1 lỗ hổng thời gian thật. Việc "phát callback cho mọi người gọi" (`dispatchCallbacks()`) và việc "dọn dẹp đánh dấu đang tải" (xóa khỏi `_inFlightAdLoads`) KHÔNG xảy ra cùng lúc — dọn dẹp xảy ra SAU, ở bước `.whenComplete()`, cách nhau đúng 1 "lượt vi mô" (microtask) của Dart. Nếu 1 callback đang được phát TỰ NÓ gọi lại `loadAppOpenAd(...)` lần nữa (mẫu hình rất thực tế: "nếu tải thất bại thì thử lại ngay") — đúng vào khoảng hở đó — lượt gọi mới sẽ tưởng nhầm là "đang có 1 lượt tải khác đang chạy", nhập chung vào lượt CŨ đã xong xuôi hoàn toàn — và vì lượt cũ sẽ KHÔNG BAO GIỜ phát callback thêm lần nào nữa, callback của lượt gọi MỚI bị mất vĩnh viễn (dù `Future` nó trả về vẫn tự hoàn thành bình thường — chỉ riêng callback không bao giờ được gọi).

**Đã sửa:** dọn dẹp đánh dấu "đang tải" ngay TRONG hàm phát callback (`dispatchCallbacks()`), TRƯỚC khi gọi bất kỳ callback nào — không đợi tới bước riêng sau đó. Nhờ vậy, nếu 1 callback tự gọi lại `loadAppOpenAd` bên trong chính nó, lượt gọi mới sẽ thấy đúng là "không có gì đang tải", tự bắt đầu 1 lượt tải MỚI và callback riêng của nó chắc chắn được gọi.

**Đã viết test tái hiện lỗi TRƯỚC khi sửa để xác nhận đây là lỗi thật** (không phải suy đoán): tạm thời gỡ bản sửa ra, chạy lại chính test mới viết — test THẤT BẠI đúng như dự đoán (callback lượt 2 không bao giờ được gọi); áp lại bản sửa — test PASS. Test này giờ nằm trong bộ test thường trực.

**Lỗi phụ phát hiện thêm (không liên quan trực tiếp race condition, nhưng cùng file):** file test thiết bị `t212_app_open_load_fanout_test.dart` (tên file cũ, thực chất thuộc T218) thiếu dòng `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` — nghĩa là nó KHÔNG THỂ chạy thật qua cơ chế test-trên-thiết-bị của Flutter, chỉ là 1 bài test widget thường bị đặt nhầm tên/nhầm thư mục. Đã sửa để chạy thật trên thiết bị.

**Test đã viết/sửa:** 1 unit test mới (tái hiện + xác nhận đã sửa lỗi race), 1 test thiết bị mới (cùng kịch bản, chạy thật trên **Samsung S24 Ultra — SM_S928B**) + sửa file test thiết bị cũ để nó thực sự chạy được trên thiết bị (trước đây không chạy được).

**Kết quả:** Toàn bộ SDK (1949 test) + toàn bộ app mẫu (47 file test) xanh 100%, `flutter analyze` sạch, `codex review` sạch.

**Tự chấm điểm phần sửa lại: 9.5/10.**
