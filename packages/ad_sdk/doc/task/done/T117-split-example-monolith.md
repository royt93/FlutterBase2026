# T117 — Tech debt: Chia example/lib/main.dart theo từng demo

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `example/lib/main.dart` (2729→~85 dòng), `example/lib/{config,bootstrap,shared,demos}/*.dart` (21 file mới)

## Vấn đề

`example/lib/main.dart` dài khoảng 2700 dòng, chứa config, splash, buffers và toàn bộ pages; thay đổi 1 demo tạo conflict và khó tìm đoạn tích hợp chuẩn. [đồng thuận 2 nguồn]

## Việc đã làm

- [x] Tách theo đúng 4 nhóm ticket yêu cầu: `config/demo_config.dart` (constants + `DemoConfig`), `bootstrap/splash_screen.dart` (`SplashScreen`), `shared/` (`log_buffer.dart`, `event_buffer.dart` + `EventRow`, `demo_tile.dart`, `home_page.dart`, `layout_helpers.dart` — `_bottomSafe` cũ, phải public hoá vì Dart privacy theo file), `demos/*.dart` — 16 file, 1 file/format (banner/mrec/native/interstitial/rewarded/app_open/vip/consent/safety/log_viewer/revenue/state_panel/events/compliance/diagnostics/test_device_hash). `main.dart` còn lại chỉ `main()` + `_navigatorKey` + barrel `export` toàn bộ 21 file trên
- [x] KHÔNG đổi key/widget text — verify bằng cách so sánh nội dung (bỏ import/comment/blank) giữa bản gốc và tổng toàn bộ file mới: khớp 100% ngoại trừ 2 dòng bị `dart format` xuống dòng khác chỗ (cùng nội dung) và rename `_bottomSafe`→`bottomSafe` (helper nội bộ, không phải Key/text nào integration test tìm)
- [x] `flutter analyze` sạch (cả `lib/` và toàn bộ example package gồm `test/` + `integration_test/`) — ban đầu có lỗi vì 8 file `example/test/*_test.dart` import `package:ad_sdk_example/main.dart` và reference trực tiếp `HomePage`/`LogBuffer`/`RevenueDemoPage`/... → giải bằng `export` barrel trong `main.dart`, KHÔNG cần sửa bất kỳ test file nào
- [x] `flutter test test/` (25 widget test trong example) chạy pass — KHÔNG chạy `integration_test/` (cần emulator/simulator, đúng như ghi chú ticket)

## Ghi chú

- Không tạo `demos/<format>/` dạng thư mục-1-file-per-format (would're over-nesting) — dùng `demos/` phẳng với 1 file/format, đã đủ "tách theo từng demo" mà ticket yêu cầu, tránh 16 thư mục con 1-file.
- `HomePage` đặt ở `shared/` (không phải file riêng) — nó là app shell/danh sách demo, không phải bản thân 1 demo, và không nằm trong 4 nhóm ticket liệt kê rõ ràng.
- `Backoff`/`AdRetryPolicy` export thay đổi ở T108 không liên quan gì file này — ghi chú riêng để tránh nhầm 2 việc trong cùng batch.
