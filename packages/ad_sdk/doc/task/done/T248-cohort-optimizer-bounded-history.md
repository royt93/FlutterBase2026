# T248 — Giới hạn lịch sử đã ký của CohortOptimizer

- **Loại:** Enhancement
- **Priority:** P2 · **Effort:** S
- **Confidence:** CONFIRMED unbounded retention; impact is gradual, not incident-proven
- **Status:** done (25/25 cohort tests; 2692/2692 full SDK tests; analyzer clean; Android TECNO KJ7 + iOS Simulator integration 1/1 each; independent audit 9.5/10)
- **Evidence:** `lib/src/monetization/cohort_optimizer.dart:55-155`; `test/cohort_optimizer_test.dart`
- **Dependency:** none

## Giá trị

Mỗi `recordSession()` tải toàn bộ record, thêm phiên mới, serialize và ký lại toàn bộ danh sách. Không thấy retention cap. Theo thời gian payload và chi phí xử lý tăng theo số phiên. Giới hạn cửa sổ lịch sử có thể giữ optimizer hữu dụng mà không tăng dữ liệu vô hạn.

## Phạm vi

- User-selected policy (2026-10-14): signed trusted-time anchor persists across writes/restarts; clock rollback more than 7 days skips time pruning and retains anchor/history. Forward wall-clock movement advances anchor and prunes, including after >7 days offline. Tradeoff: forward clock jump can prune early; wall clock alone cannot distinguish it from inactivity. Legacy list migrates using newest legacy timestamp as initial anchor.
- Rollback <=7 days prunes stale/future records without moving anchor backward (strictly monotonic anchor).
- Records remain a signed top-level JSON list under the existing stable key so older SDK versions can read/append/write it without losing prior rows. Trusted clock anchor uses a separate signed preference key.
- Verified non-list records payload or invalid separately signed anchor is treated as absent/corrupt; record history remains readable and future writes continue. Inside the recognized legacy list, malformed individual rows (including missing numeric fields or unknown provider) are dropped; valid rows are kept and writes continue (owner-selected 2026-10-14).
- Recommendation filters records to `[now-90d, now]` and excludes future timestamps.
- Hard cap 100 most-recent append-order records; accepted tradeoff: high-volume provider may evict other provider’s samples, yielding `null` recommendation below minimum sample count.
- Legacy schema has no trusted anchor; first migration cannot detect clock skew that occurred before anchor initialization.
- Cắt record trước khi ký/lưu; giữ nguyên xác minh chữ ký và fallback khi payload bị sửa/hỏng.
- Không thay thuật toán chọn provider, không thêm backend hay thu thập telemetry.

## Acceptance criteria

- [x] Unit: legacy signed-list read/write; separately signed anchor persists across writes/restart; downgrade simulation appends with old list format and re-upgrade preserves history.
- [x] Unit: >7d offline advances anchor and prunes >90d rows; backward rollback >7d preserves stale/future rows; exactly 7d and +1ms boundaries verified deterministically.
- [x] Unit: recommendations always ignore records outside `[now-90d, now]`; tampered payload rejected; signature valid after rewrite.
- [x] Unit: hard cap 100 rows and accepted positional provider eviction.
- [x] Unit: records-write false preserves previous records/anchor; anchor-write false rolls records back (also removes first-write records); simultaneous anchor+rollback failure reports both; persistence failure seams are ignored in release-simulated mode.
- [x] Widget test: N/A — optimizer không có UI; integration test chứng minh persistence/storage trên thiết bị.
- [x] Android/iOS integration: synthetic signed history is trimmed, re-signed and readable on device/simulator; 1/1 each.
- [x] Smoke device tests use synthetic records only; no production ad traffic.
- [x] Unit: malformed rows in a recognized schema (including invalid provider strings) are dropped, valid rows kept, next write re-signs; unknown schema untouched.
- [x] Unit: concurrent `recordSession` writes are serialized through an async write queue.
- [x] Fresh independent review of exact final diff; score 9.5/10, no unresolved code findings. Earlier audits found and drove fixes for anchor freeze, malformed-row lockout, downgrade compatibility, write race, provider validation, deterministic boundaries, and persistence rollback.

## Tiến độ thực tế (2026-10-14)

- Records vẫn là signed top-level JSON list tại key ổn định; trusted clock anchor lưu riêng dưới một signed preference key. Bản SDK cũ vẫn đọc/append/ghi được list, tránh mất history khi downgrade.
- Ghi mới so wall clock với anchor đã ký: rollback >7 ngày giữ records và anchor; rollback <=7 ngày giữ anchor (monotonic non-decreasing); forward time (kể cả sau >7 ngày offline) tiến anchor lên `now` và prune records ngoài `[now-90d, now]`. Ghi records phải thành công trước khi cập nhật anchor; `setString == false` hoặc exception khi ghi records được báo lỗi. Nếu ghi anchor lỗi sau khi records đã ghi, khôi phục raw records trước đó (hoặc xóa nếu chưa có); nếu rollback cũng lỗi thì exception nêu rõ cả hai lỗi.
- Concurrent `recordSession()` calls được tuần tự hóa trong cùng Dart isolate để tránh lost updates ở process hiện tại; writers ở các isolate/Flutter engines khác nhau không được phối hợp nguyên tử qua SharedPreferences. Row sai định dạng (kể cả thiếu số/provider lạ hoặc metrics âm) bị bỏ riêng; row hợp lệ vẫn được dùng. Unknown non-list payload được giữ nguyên (no-op ghi).
- Recommendation độc lập lọc wall-clock `[now-90d, now]`; records giữ lại trong rollback không tham gia recommendation cho tới khi clock quay về cửa sổ.
- Cohort focused tests 25/25 pass; analyzer clean; full SDK suite 2692/2692 pass. T146 integration pass on Android TECNO KJ7 (1/1) and iOS Simulator (1/1), synthetic data only.
- Final independent adversarial audit score 9.5/10; no unresolved code findings. Task completed; no commit or push performed.

## Prompt vòng lặp

Triển khai T248 theo TDD. Trước tiên đọc lại optimizer, test và task T90/T93/T97/T136/T146 để không thay đổi chính sách cohort đã chọn. Viết test retention, boundary, signature, recommendation và persistence failure trước khi sửa. End loop: audit changes + điểm /10; unit/widget/integration test mọi case (widget N/A phải có lý do), smoke trên thiết bị bằng dữ liệu tổng hợp; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.
