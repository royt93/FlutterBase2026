# T266 — Tối Ưu Hóa Cơ Chế Thử Lại Mạng Bằng Jitter Ngẫu Nhiên (Decorrelated Jitter & Exponential Backoff)

- **Loại:** Enhancement / Network Resilience
- **Priority:** P2 · **Severity:** LOW
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Khi thiết bị vừa phục hồi kết nối Internet sau một khoảng thời gian mất mạng:
- Hiện tại `_onConnectivityChanged` đợi 800ms debounce rồi đồng loạt kích hoạt nạp lại toàn bộ các vị trí quảng cáo (`_retryRefillAds`).
- Trong các trường hợp mạng yếu hoặc mạng công cộng (Wi-Fi trường học, sân bay, quán cafe) nơi có hàng trăm thiết bị cùng kết nối lại đồng thời: việc bắn hàng loạt request cố định đúng 800ms tạo ra hiệu ứng thundering herd (nghẽn mạng cục bộ), khiến request đầu tiên dễ bị timeout hoặc lỗi socket `Connection closed before receiving data`.

## Đề xuất giải pháp

1. Bổ sung thuật toán **Full Jitter** vào chu kỳ thử lại mạng:
   `actualDelay = baseDebounce + random(0, baseDebounce * 0.5)`.
2. Phân tầng thời điểm nạp giữa các slot (Staggered Refill): nạp Banner trước, 500ms sau nạp Interstitial, 500ms sau nạp Rewarded để dàn đều băng thông mạng.

## Acceptance Criteria

- [ ] Giảm thiểu tỷ lệ lỗi timeout khi vừa có mạng trở lại.
- [ ] Dàn đều tải mạng giữa các định dạng quảng cáo.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra phân phối ngẫu nhiên của jitter và tính toán thời gian chờ.
- **Network conditioning test:** Bật tắt mạng liên tục, assert thứ tự nạp ad diễn ra tuần tự an toàn.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T266 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/ad_manager.dart.
2. Viết test trước để kiểm tra cơ chế jitter mạng (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
