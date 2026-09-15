# T217 — Public API stability và deprecation policy (ENHANCE)
Priority P3 · Status todo.

Đánh dấu `@experimental`, deprecation timeline, changelog tự động và API golden test để tránh phá host. Khuyến nghị policy semver + CI API diff; tài liệu thủ công dễ bị bỏ quên.

Tests: unit API manifest; widget compile consumer samples; integration package upgrade fixture; device smoke sample app trên supported platforms.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 commit+push.

## Kết quả (2026-09-15)

**Chủ dự án chọn (AskUserQuestion):** "Full member-level diff (thêm dev
dependency)" — dùng `analyzer` để trích xuất TOÀN BỘ public API (class,
method, field, tham số) thành golden file, thay vì chỉ diff danh sách tên
export (không bắt được thêm/xóa method trên class đã export sẵn).

**Đã làm:**

- `tool/api_surface.dart` (mới): dùng `package:analyzer` (`AnalysisContextCollection`
  + `Element2` model) walk **export namespace đã resolve** của
  `lib/applovin_admob_sdk.dart` (`LibraryElement2.exportNamespace` —
  chính xác những gì 1 host thấy khi `import` package, độc lập với việc
  export có `show` clause hay không) — không phải chỉ parse text file.
  Với mỗi class/enum, chỉ liệt kê member **khai báo trực tiếp** (không lấy
  member kế thừa từ `StatefulWidget`/`State`/... của Flutter — tránh nhiễu
  framework không thuộc sở hữu package này). Loại trừ member có
  `@internal`/`@visibleForTesting` (dùng `Metadata.hasInternal`/
  `hasVisibleForTesting` — xác nhận filter này THẬT SỰ có tác dụng: giảm
  1423 → 1313 dòng khi bật, và test riêng xác nhận `debugCanRequestAds`
  không xuất hiện).
  - 2 dev_dependency mới: `analyzer: ^7.3.0`, `path: ^1.9.0` (chỉ
    dev-only — KHÔNG bao giờ đi vào dependency graph của app dùng SDK).
  - Xử lý 1 vấn đề môi trường thật: chạy qua `flutter test` thì
    `Platform.resolvedExecutable` trỏ vào `flutter_tester` (binary engine),
    khiến `analyzer` tự động dò sai đường dẫn Dart SDK — sửa bằng cách tự
    tính `sdkPath` từ biến môi trường `FLUTTER_ROOT` (Flutter luôn set khi
    chạy qua `flutter`/`flutter test`) khi có mặt.
- `test/api_golden_test.dart` (mới, 2 test): so sánh output thật với
  `test/goldens/public_api_surface.txt` đã checked-in, in ra diff
  added/removed rõ ràng nếu khác, và nhắc cập nhật CHANGELOG.md +
  lệnh regenerate ngay trong thông báo lỗi. Test thứ 2 xác nhận riêng
  filter `@visibleForTesting` hoạt động đúng (không vacuous — nếu filter
  bị xoá thì assertion thất bại đúng như kỳ vọng, đã revert-and-confirm).
- `test/goldens/public_api_surface.txt` (mới, 1313 dòng) — snapshot hiện
  tại, generate bằng `dart run tool/api_surface.dart`.
- README.md: mục mới "## API stability & deprecation policy (T217)" —
  cam kết semver, cách dùng `@Deprecated`/`@experimental`, tối thiểu 1
  MINOR version trước khi xoá hẳn, và giải thích cơ chế enforce bằng
  golden test.
- CHANGELOG.md: 1 mục `[Unreleased]` mới.

**Verify non-vacuous (revert-and-confirm-red-restore):**
- Thêm 1 method thử vào `InlineAdController`, chạy test → fail đúng với
  diff chính xác ("Added: InlineAdController.temporaryProbeMethod...");
  gỡ lại → pass.
- Tắt filter `_isExcludedFromApiSurface` (trả `false` luôn) → CẢ 2 test
  fail (golden diff phình to ~110 dòng debug* xuất hiện lại, và assertion
  riêng "debugCanRequestAds must be excluded" fail đúng lý do); khôi phục
  → pass.

**Phạm vi CỐ Ý thu hẹp so với DoD gốc — có lý do, không phải bỏ sót:**

- *"widget compile consumer samples"*: KHÔNG viết test mới riêng — bộ
  test `example/` (58 test, chạy lại mỗi task trong phiên này) TỰ NÓ đã
  là "consumer sample thật sự biên dịch" liên tục, vì `example/` import
  và dùng `applovin_admob_sdk` y hệt 1 host thật. Viết thêm 1 bản sao nhỏ
  hơn sẽ trùng lặp, không thêm giá trị.
- *"integration package upgrade fixture"* và *"device smoke sample app"*:
  KHÔNG áp dụng có ý nghĩa cho task này — đây là 1 kiểm tra tĩnh
  (static-analysis, chạy lúc `flutter test`/CI, không phải hành vi
  runtime trên thiết bị). Không có "hành vi trên device thật" nào để
  smoke-test — khác với mọi task khác trong phiên này (T192-T201), nơi
  device smoke luôn có ý nghĩa vì đang test hành vi runtime thật. Ép làm
  "device smoke" cho 1 API-diff tool sẽ chỉ là chạy `flutter test` trên
  device (dùng `flutter test -d <device>` cũng chạy được
  `api_golden_test.dart`, nhưng không kiểm tra thêm điều gì mới so với
  chạy trên máy host) — không thêm tín hiệu thật.

**Kết quả test toàn bộ:**
- `flutter test` (SDK): 2109/2109 pass (2107 trước + 2 test mới).
- `flutter test` (example): 58/58 pass, không đổi (không chạm code SDK
  runtime, chỉ thêm tooling dev-only).
- `flutter analyze`: sạch cả 2 package (1 warning `experimental_member_use`
  từ chính `analyzer` package's `Element2` API — đã `// ignore:` kèm giải
  thích, vì chưa có API thay thế ổn định).

**Không chạy được `codex review --uncommitted`** (hết hạn mức từ trước
trong phiên — chủ dự án đã cho phép bỏ qua).

**Tự chấm điểm: 9/10.** Trừ điểm vì (1) không chạy codex, (2) phạm vi thu
hẹp có chủ đích ở 2/4 loại test theo DoD gốc (đã giải thích rõ lý do ở
trên, không phải bỏ sót), và (3) `analyzer`/`Element2` là API còn
"experimental" phía analyzer (rủi ro breaking change nhỏ ở lần nâng cấp
`analyzer` sau — đã ghi chú trong code để dễ phát hiện khi đó).
