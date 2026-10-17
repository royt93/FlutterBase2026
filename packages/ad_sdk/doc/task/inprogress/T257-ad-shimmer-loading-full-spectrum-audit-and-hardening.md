# T257 — Toàn diện Ad Shimmer Loading: Tối ưu Ticker, Dark Mode, Khung Test Đa Chiều

- **Loại:** Hardening / Enhancement / Performance
- **Priority:** P0 · **Severity:** HIGH
- **Status:** inprogress (đang triển khai)

## Bối cảnh & Vấn đề

Trong `lib/src/widget/shimmer_view.dart`, `ShimmerView` được sử dụng làm placeholder trong suốt quá trình nạp quảng cáo Banner, MREC và Native. Qua rà soát mã nguồn và đo đạc thực tế trên Google Pixel 7 Pro, phát hiện các hạn chế nghiêm trọng:
1. **Lãng phí CPU/GPU và Ticker chạy ngầm:** `AnimationController(..repeat())` chạy liên tục chu kỳ 1200ms bằng `ShaderMask`. Khi ứng dụng bị đưa vào background hoặc chuyển sang route khác mà không unmount, Ticker vẫn tiếp tục tiêu tốn chu kỳ GPU và pin, góp phần gây ra tỷ lệ giật khung hình (29.79% jank đo được ở bản debug).
2. **Lỗi hiển thị Dark Mode (Gây chói mắt người dùng):** Màu gradient cố định `Color(0xFFE0E0E0)` và `Color(0xFFF8F8F8)` là màu xám trắng. Trên ứng dụng nền tối (Dark Theme), placeholder lóe sáng trắng đột ngột trước khi ad hiện, gây trải nghiệm người dùng rất xấu và vi phạm quy chuẩn thiết kế.
3. **Mất mạng & Timeout:** Khi thiết bị mất mạng, nếu nạp quảng cáo bị treo hoặc backoff kéo dài, shimmer chạy vô tận mà không có cơ chế timeout chuyển sang trạng thái lỗi hoặc sụp khoảng trống (collapse) mượt mà.
4. **Thiếu kiểm thử đa chiều:** Chưa có bộ test toàn diện bao phủ Golden test, Interruption (tắt màn hình/cuộc gọi), Network conditioning (mất mạng/phục hồi), đo rò rỉ bộ nhớ Ticker và đo Frame rate/jank.

## Đề xuất giải pháp

1. **Dark Mode Aware:** Hỗ trợ tự động nhận diện `Theme.of(context).brightness` để chuyển sang dải màu xám tối phù hợp (`0xFF2A2A2A` / `0xFF3A3A3A`) khi ở dark mode.
2. **Lifecycle Aware Ticker:** Tích hợp với `RouteAware` / `WidgetsBindingObserver` để tự động `.stop()` controller khi app backgrounded hoặc route bị che khuất, và `.repeat()` lại khi foreground.
3. **Graceful Collapse on Timeout:** Sau khoảng thời gian nạp quá lâu (ví dụ 10s) mà không có kết quả từ provider, shimmer tự động hạ opacity hoặc chuyển sang trạng thái error-collapse để không giữ chỗ vô ích.

## Acceptance Criteria

- [ ] `ShimmerView` hỗ trợ màu Dark Mode tự nhiên theo theme hiện tại của ứng dụng.
- [ ] Ticker tự động dừng khi route bị ẩn hoặc ứng dụng chuyển sang chế độ background, phục hồi khi trở lại foreground.
- [ ] Không có memory leak từ `AnimationController` hoặc `TickerProvider`.
- [ ] Golden test xác minh pixel hiển thị chính xác ở cả Light mode và Dark mode.
- [ ] Interruption test xác minh vòng đời `paused`/`resumed` không gây crash hay rò rỉ Ticker.
- [ ] Network conditioning test: khi mất mạng giữa chừng, shimmer tự chuyển sang trạng thái collapse an toàn, không giật lag.
- [ ] Frame rate/jank test: giảm thiểu frame drop, đạt 60fps ổn định trên thiết bị vật lý.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Tiến độ thực tế (2026-10-17) — CHƯA đủ điều kiện done

Đã xong:
- Dark Mode theo Theme (tự động nhận diện `Theme.of(context).brightness`, dải màu tối `[0xFF2A2A2A, 0xFF383838]`).
- Ticker dừng khi app paused/inactive/hidden qua `WidgetsBindingObserver`, phục hồi khi resumed.
- Cờ `active` render Container tĩnh 0 overhead khi inactive.
- 13 widget tests + 2 golden tests (`shimmer_view_light.png`, `shimmer_view_dark.png`).
- Khảo sát thực tế trên Pixel 7 Pro (chụp được shimmer rendering ở mốc 200ms, sau đó ad test nạp thành công, 0 fatal exception).
- **Cơ chế Watchdog Timeout & Collapse:** Đã xác minh bằng test end-to-end `test/banner_ad_widget_test.dart` ("T257: watchdog error removes shimmer and collapses banner"). Khi sàn quảng cáo bị treo quá thời hạn watchdog 30s của Adapter, `hasError` được kích hoạt, `BannerAdWidget` tự động gỡ bỏ `ShimmerView` và animate thu nhỏ chiều cao về 0 (`SizedBox.shrink()`). Không cần và không nên đặt timer riêng trong `ShimmerView` để tránh desync trạng thái giữa visual layer và `AdSlot` của Adapter.

Còn thiếu (không được tick done khi chưa làm):
- [ ] Chưa thu `FrameTiming`/`dumpsys gfxinfo` trên thiết bị thật lúc shimmer đang chạy liên tục.
- [ ] Chưa đo PSS/heap allocations native khi lặp mount/dispose trên profile build.
- [ ] Chưa có audit độc lập chấm điểm >9/10.

Bằng chứng hiện tại chứng minh Shimmer render tốt trên Pixel 7 Pro, tự dừng ticker khi app background, và sụp khoảng trống an toàn khi timeout nổ; chưa chứng minh benchmark 60fps/memory bằng số liệu profile.


## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra khởi tạo controller, timer fallback và logic tính toán gradient color.
- **Widget test:** Kiểm tra widget mount/unmount, dark mode rendering, và hủy controller khi dispose.
- **Golden test:** Sinh và assert visual golden `shimmer_light.png` và `shimmer_dark.png`.
- **Interruption test:** Giả lập `AppLifecycleState.paused` rồi `resumed`, assert Ticker state.
- **Network conditioning test:** Bật/tắt kết nối mạng mô phỏng, kiểm tra hành vi collapse.
- **Memory & Profiling test:** Chạy 30 vòng mount/unmount kiểm tra heap không giữ tham chiếu Ticker.
- **Frame rate/Jank test:** Đo `FrameTiming` assert 0 frame vượt ngưỡng 16.6ms do ShimmerView.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T257 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/shimmer_view.dart, banner_ad_widget.dart, mrec_ad_widget.dart, native_ad_widget.dart.
2. Viết test trước để chứng minh hạn chế hiện tại (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
