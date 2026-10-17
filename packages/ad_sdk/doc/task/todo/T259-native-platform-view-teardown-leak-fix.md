# T259 — Vá Rò Rỉ Native Platform View Khi NativeAdWidget Unmount Giữa Lúc Nạp

- **Loại:** Bug Fix / Memory Leak Hardening
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Khi ứng dụng sử dụng `NativeAdWidget` với custom `factoryId` (do host app tự đăng ký layout native ở tầng Android/iOS):
- Quá trình nạp native ad diễn ra bất đồng bộ qua Platform Channel (`FlutterNativeAd.load`).
- Nếu người dùng điều hướng nhanh (pop màn hình, chuyển tab) ngay trong lúc native ad đang được nạp dở: widget State bị `dispose()`, nhưng callback platform channel khi hoàn tất vẫn tạo ra đối tượng Native Ad và giữ một Platform View ID trên native heap.
- Do không có cơ chế hủy nạp giữa chừng gắn với instance key của widget trong `inline_ad_instance_registry.dart`, đối tượng Native Ad trên native layer không được gọi `.destroy()` / `.dispose()`, dẫn đến rò rỉ bộ nhớ đồ họa (Graphic Memory / Native Heap leak) sau nhiều lần chuyển màn hình.

## Đề xuất giải pháp

1. Trong `inline_ad_instance_registry.dart`, bổ sung cờ trạng thái `isDisposed` theo từng instance ID.
2. Khi `NativeAdWidget` gọi `dispose()`, đánh dấu instance đã hủy.
3. Khi callback `onNativeAdLoaded` trả về từ Platform Channel: nếu instance ID tương ứng đã bị dispose trong lúc chờ, lập tức gọi `ad.dispose()` ngay tại tầng native bridge thay vì gán vào registry.

## Acceptance Criteria

- [ ] Nếu widget bị dispose trước khi nạp xong, native ad instance trả về sau đó phải được giải phóng ngay lập tức (`ad.dispose()`).
- [ ] Không còn platform view mồ côi (orphaned platform view) tồn tại sau khi unmount màn hình.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Giả lập độ trễ Platform Channel 500ms, gọi dispose widget ở ms 100, xác nhận `bridge.disposeAd` được gọi đúng 1 lần.
- **Widget test:** Mount `NativeAdWidget`, lập tức unmount trước khi Future hoàn tất, assert không có unhandled error.
- **Memory profiling test:** Lặp lại 50 vòng mount/unmount nhanh, kiểm tra Native Heap ổn định.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T259 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/native_ad_widget.dart, lib/src/adapters/inline_ad_instance_registry.dart, lib/src/adapters/admob_adapter.dart.
2. Viết test trước để tái hiện rò rỉ platform view khi unmount nhanh (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
