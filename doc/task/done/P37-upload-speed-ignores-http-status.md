# P37 — `UploadSpeedService` không kiểm `statusCode`, dễ báo sai khi captive portal/lỗi HTTP

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** codex CLI (audit độc lập, đã verify lại trực tiếp)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/upload_speed_service.dart:19,26-40`

## Vấn đề
`Dio` được khởi tạo với `validateStatus: (_) => true` (dòng 19) — không bao giờ throw vì status code. `measure()` (dòng 26-40) chỉ đo thời gian `_dio.post(...)` chạy (dòng 30), **không đọc `response.statusCode`** trước khi tính Mbps. Nếu mạng có captive portal (trả HTML login page, status 200 nhưng không phải endpoint thật) hoặc server trả lỗi (403/500) nhanh, code vẫn tính ra 1 con số Mbps từ thời gian round-trip đó — báo sai tốc độ upload thay vì báo lỗi/`null`.

## Bằng chứng
- `upload_speed_service.dart:19` — `validateStatus: (_) => true`.
- `upload_speed_service.dart:30-34` — không dùng `response.statusCode`.

## Việc cần làm (đề xuất, chưa code)
- Sau `final response = await _dio.post(...)`, kiểm `response.statusCode == 200` (hoặc range 2xx) trước khi tính Mbps; trả `null` nếu không phải 2xx.

## Acceptance criteria
- [ ] Mock server trả 403/500 → `measure()` trả `null`, không trả số Mbps giả.
- [ ] Unit test cover case status 200 (đo đúng) và status lỗi (trả null).
