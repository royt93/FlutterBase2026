# P30 — ⭐ Tính năng độc quyền: Bản đồ vùng sóng yếu theo phòng (Room Coverage / Dead-Zone Map)

- **Priority:** P1 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận mạnh 3 nguồn]** codex CLI + agy CLI + claude CLI — điểm đồng thuận cao nhất trong toàn bộ audit, cả 3 AI độc lập đều xếp đây là ý tưởng khác biệt hàng đầu.
- **Files liên quan (đã có sẵn):** `widgets/room_tag_bottom_sheet.dart`, `presentation/room_comparison_screen.dart`, `models/test_result.dart` (field `roomTag`, `packetLossPct`, `avgLatencyMs`), `services/test_history_storage.dart` (Hive)

## Ý tưởng
Biến flow gắn `roomTag` hiện tại (thủ công, rời rạc) thành 1 flow dẫn dắt: user đi từng phòng trong nhà, bấm test ở mỗi phòng → app tự động xếp hạng phòng yếu nhất/mạnh nhất, tổng hợp thành bản đồ vùng sóng yếu (dead-zone map), gợi ý vị trí đặt lại router/mesh node. **Không đối thủ nào (Speedtest.net, Fast.com) có tính năng này** — họ chỉ test 1 điểm, không có khái niệm lịch sử theo vị trí.

## Việc cần làm (đề xuất — cần thiết kế UX riêng trước khi ước lượng effort, chưa code)
- Thiết kế flow "Walk Test": màn hình hướng dẫn từng bước, mỗi bước = 1 phòng, bấm test, gắn tên phòng ngay (tái dùng `room_tag_bottom_sheet.dart`).
- Màn hình tổng kết: xếp hạng phòng theo tốc độ/packet loss/latency, highlight phòng yếu nhất.
- Gợi ý hành động đơn giản dựa trên rule-based (không cần ML): "phòng X yếu nhất, cân nhắc đặt mesh node gần đó" — dùng vị trí tương đối do user tự sắp xếp (không cần định vị chính xác thật).
- Phụ thuộc: P24 (retro-tag test cũ) để không lãng phí dữ liệu lịch sử đã có; P17 (room × time grid) có thể tái dùng chung UI component.
- Đây là feature lớn, cần 1 task riêng để thiết kế UI/UX chi tiết trước khi rã sang task con implement.

## Bổ sung (2026-08-11, audit vòng 2 — codex CLI)
2 hướng mở rộng đáng cân nhắc khi thiết kế UX (không phải task bắt buộc, ghi lại để không quên):
- **Signed Room Walk Certificate**: xuất report tamper-evident (ký Ed25519, cùng nguyên lý [[P31-exclusive-isp-evidence-mode]]) chứng nhận đã walk-test đủ N phòng trong nhà — khác P31 ở việc trọng tâm là *coverage theo phòng*, không phải *ISP dispute*.
- **Router Placement Experiment Mode**: dùng lại chính flow walk-test này để so sánh "trước/sau" khi user di chuyển router/mesh node — so từng phòng theo lịch sử `roomTag` đã lưu, không cần tính năng mới, chỉ cần UI filter theo khoảng thời gian đặt trước/sau 1 mốc.

## Acceptance criteria
- [ ] Có thiết kế UX cụ thể (wireframe/flow) trước khi bắt đầu code.
- [ ] User có thể hoàn thành 1 "walk test" qua ≥2 phòng và xem được bảng xếp hạng + gợi ý.
- [ ] Tận dụng lại `room_comparison_screen.dart`/`room_tag_bottom_sheet.dart` hiện có, không viết lại từ đầu.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
[[P17-room-heatmap-merge]] (lưới phòng × thời gian) đã đóng và coi là Phase 1/nằm trong scope của ticket này — khi thiết kế UX cho walk-test flow, nhớ đưa luôn phần lưới phòng×thời gian của P17 vào, không code 2 lần.
