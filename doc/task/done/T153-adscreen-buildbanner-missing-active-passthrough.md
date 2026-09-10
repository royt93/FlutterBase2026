# T153 — Hàm tiện lợi tích hợp banner/MREC làm rơi mất công tắc "đang hiển thị"

**Loại:** bug
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config, tự verify (cùng dạng lỗi T107 đã sửa cho `placement`)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Có 1 hàm tiện lợi (`AdScreenState.buildBanner()`/`buildMrec()`) giúp dev tích hợp nhanh mà không phải tự viết nhiều dòng — đây chính là cách tích hợp CHUẨN được khuyến nghị trong README (mục 5). Hàm này thiếu chuyển tiếp 1 công tắc "có đang hiển thị hay không" (`active`, dùng cho trường hợp nhiều tab, chỉ tab đang mở mới tính là hiển thị). Dev nào dùng đúng hàm tiện lợi này (thay vì tự viết thủ công) sẽ bị rơi mất công tắc đó — gây lại đúng lỗi "đếm nhầm lượt xem" (xem T154) nhưng qua đường khác, và phá vỡ đúng use-case chính mà `active` được thêm vào (tab `IndexedStack`).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_screen.dart:56-66` — `buildBanner()`/`buildMrec()` chỉ forward `placement` xuống `BannerAdWidget`/`MrecAdWidget`, không forward `active`.
- Comment ngay tại đó (từ lần sửa T107 cho `placement`): "without this... every per-placement cap/stat host apps actually use this helper for silently stayed on AdPlacement.unspecified" — `active` bị bỏ sót y hệt kiểu lỗi đó.

## Việc cần làm
1. Thêm tham số `active` (mặc định `true` để không breaking) vào `buildBanner()`/`buildMrec()`, forward xuống đúng `BannerAdWidget`/`MrecAdWidget`.
2. Grep các hàm helper tương tự khác trong `ad_screen.dart` (nếu có, VD native) để đảm bảo không bỏ sót thêm.
3. Thêm log SafeLogger không cần thiết ở đây (đây là API passthrough đơn giản) — nhưng đảm bảo test phủ đủ.
4. Thêm demo trong `example/`: 1 màn hình dùng `AdScreenState.buildBanner(active: ...)` trong `IndexedStack` nhiều tab, chứng minh banner không load/đếm khi tab không active.
5. Cập nhật CHANGELOG.md và README.md (mục 5 — API `buildBanner`/`buildMrec`).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_screen.dart dòng ~56-66: AdScreenState.buildBanner()/buildMrec() hiện chỉ forward placement xuống BannerAdWidget/MrecAdWidget, thiếu forward tham số active (đã có sẵn trên BannerAdWidget/MrecAdWidget từ round-31/round-39, dùng cho case IndexedStack nhiều tab). Thêm tham số active (default true, không breaking) vào cả 2 hàm, forward đúng xuống widget con. Kiểm tra có hàm buildNative tương tự không, áp dụng nhất quán. Viết widget test: dùng buildBanner(active: false) trong 1 tab ẩn của IndexedStack, xác nhận banner không load/không tính lượt xem cho tới khi active chuyển true. Thêm demo trong example/. Cập nhật README.md mục 5.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho `buildBanner`/`buildMrec` với `active: false/true` trong `IndexedStack`; test không breaking cho code cũ không truyền `active`.
3. Demo trong `example/` + CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, chuyển tab qua lại trong demo, xác nhận banner chỉ hoạt động ở tab đang mở.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-10)

**Fix:** `AdScreenState.buildBanner()`/`buildMrec()`/`buildNative()` (`ad_screen.dart`)
đều thêm tham số `active`, forward xuống widget con:
- `buildBanner`/`buildMrec`: `bool? active` (mặc định `null` — KHÔNG phải
  `true` như bản kế hoạch ban đầu ghi. `true` sẽ làm hỏng hành vi tự động
  hiện tại: `BannerAdWidget`/`MrecAdWidget` dùng `null` để nghĩa "tự quyết
  định qua `VisibilityDetector`" — set cứng `true` sẽ khoá luôn on, phá mất
  auto-pause khi cuộn khuất màn hình bình thường (không phải IndexedStack).
  Đã tự sửa lại default cho đúng với ý nghĩa thật của tham số, không làm
  theo mù quáng bản kế hoạch viết trước khi đào sâu implementation).
- `buildNative`: `bool active = true` (không nullable — khớp với
  `NativeAdWidget.active` sau T154, không có tầng "tự động").

**codex review:** sạch ngay vòng 1 — "0 findings across the reviewed
diff... forwarding matches existing widget defaults, tests exercise both
paths."

**Test:**
- Unit (`test/ad_screen_test.dart`): 2 case mới — forward `active` đúng
  xuống cả 3 widget khi truyền tường minh; bỏ qua tham số vẫn giữ đúng
  default cũ của từng widget (không breaking).
- Widget (`example/test/banner_demo_page_test.dart`, mới): chuyển tab
  IndexedStack trước khi SDK init không crash.
- Integration (`example/integration_test/banner_indexedstack_visibility_test.dart`,
  mới, chạy thật trên **Pixel 7 Pro**, `--dart-define=AD_PROVIDER_ADMOB=true`):
  xanh hoàn toàn — chuyển tab 1↔2 qua `buildBanner(active: ...)` (đường
  tích hợp CHUẨN, không phải constructor thô), banner tab 2 chỉ mount khi
  active, không crash.

**Demo:** thêm card "IndexedStack via buildBanner() (T153)" vào
`BannerDemoPage` — 2 nút chuyển tab, tab 2 chứa `buildBanner(active:
_tabIndex == 1)`.

**Docs:** README.md — cập nhật bảng API reference (`buildBanner({placement,
active})` v.v.) + thêm ghi chú ngay tại ví dụ `buildBanner()` giải thích
cách dùng `active` cho IndexedStack.

**Suite:** 1806/1806 (`packages/ad_sdk`), 39/39 (`example`). `flutter
analyze` sạch cả 2 package.

**Điểm tự chấm:** 9.5/10 — fix đơn giản, đúng bản chất tham số (tự phát
hiện và sửa sai lệch trong kế hoạch ban đầu về default value), codex sạch
ngay vòng 1, có bằng chứng device thật.
