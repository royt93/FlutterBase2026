# T249 — Ràng buộc dữ liệu đầu vào cohort metrics

- **Loại:** Fix candidate / boundary validation
- **Priority:** P3 · **Effort:** S
- **Confidence:** CONFIRMED boundary gap — public host-supplied metrics had no non-negative contract or validation
- **Status:** done (non-negative metrics validated before persistence; tests, analyzer, full suite 2695/2695 pass; independent audit 9.5/10)
- **Evidence:** `lib/src/monetization/cohort_optimizer.dart:59-79,128-139`; `test/cohort_optimizer_test.dart`
- **Dependency:** T248 chỉ nếu chọn chung semantics retention

## Giá trị

`recordSession()` nhận `impressions` và `revenueMicros` từ caller công khai, rồi đưa trực tiếp vào phép tính eCPM. Số âm có thể làm lệch gợi ý provider, nhưng chưa xác minh có caller hợp lệ nào truyền dữ liệu sai hay contract hiện tại cho phép số âm. Xác định contract trước; không thêm validation cho input không thể xảy ra theo contract.

## Phạm vi

- Tra cứu toàn bộ call sites, docs và model semantics: repo không có caller ngoài tests; API được export; không có doc định nghĩa miền; AppLovin bỏ revenue <=0 còn AdMob chuyển raw paid value.
- Owner chọn contract non-negative: `recordSession` ném `ArgumentError` đồng bộ trước persistence cho `impressions < 0` hoặc `revenueMicros < 0`; `0` hợp lệ.
- Giữ `0` impressions/revenue hợp lệ nếu product semantics hiện tại yêu cầu.
- Không đổi thuật toán optimizer hay đổi data từ provider.

## Acceptance criteria

- [x] Kết luận contract: caller public cung cấp session metrics; `impressions` và `revenueMicros` không âm, zero hợp lệ.
- [x] Unit: reject số âm độc lập cho từng field trước khi enqueue/persist; zero và số dương lớn nhất được accept; từ chối không mutate records hoặc anchor. Verified: focused cohort tests, API golden, analyzer clean, full SDK suite 2695/2695.
- [x] Contract non-negative được enforce tại API boundary; public docs và Unreleased changelog ghi rõ, không đổi signature/API golden.
- [x] Widget test: N/A — không có UI.
- [x] Integration Android/iOS: N/A — `recordSession()` là API Dart public, không gọi bridge/native; validation xảy ra trước persistence và platform code.
- [x] Smoke device: N/A — pure Dart input validation, không có ad/runtime behavior mới; zero/negative synthetic metrics covered by unit tests, no real ads used.
- [x] Audit độc lập diff/contract: 9.5/10, no findings.

## Prompt vòng lặp

Điều tra T249 trước khi sửa. Đọc mọi call site, API docs và test; không mặc định số âm là lỗi nếu contract chưa xác nhận. Nếu boundary cần validate, viết test đỏ trước, bảo đảm không ghi đè state hợp lệ khi input bị reject. End loop: audit lại changes, chấm /10; bổ sung unit/widget/integration theo tính áp dụng, smoke thiết bị nếu có runtime behavior; chỉ khi test/analyze pass và điểm >9/10 mới commit/push theo yêu cầu task. Nếu không cần code, ghi rõ chứng cứ và kết luận REFUTED.