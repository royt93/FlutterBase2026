# T258 — Staging Mode cho Phép Nạp Test Ads ở Profile Build để Đo RAM & Jank Benchmark

- **Loại:** Enhancement / Tooling / Performance
- **Priority:** P0 · **Severity:** HIGH
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Trong lượt audit Round 75 và các phép đo thực tế trên Google Pixel 7 Pro:
- Phép đo RAM (PSS) trên **Debug build** qua 20 chu kỳ Banner cho thấy RAM tăng từ 619.4 MB lên 671.1 MB (+51.7 MB) và 29.79% jank (129/433 frames). Tuy nhiên, số liệu debug bị nhiễu lớn bởi máy ảo Dart VM và logcat hệ thống.
- Khi biên dịch sang **Profile build** (`app-profile.apk`) để đo chính xác bằng DevTools/heap dump thì SDK kích hoạt chốt chặn an toàn `_testIdFootgunBlocked`: SDK tự động khóa `canRequestAds = false` khi phát hiện Google test ad unit IDs trong profile/release nhằm bảo vệ tài khoản nhà phát triển không bị Google phạt do phát test ads trong release.
- **Hậu quả:** Không thể thực hiện bài đo RAM và giật lag (Jank) chuẩn xác trên Profile build trên thiết bị vật lý nếu chưa có Ad Unit ID thật từ tài khoản production.

## Đề xuất giải pháp

1. Thêm cờ cấu hình tường minh có kiểm soát trong `AdConfig`:
   `allowTestAdsInProfileForStaging: true` (mặc định luôn luôn là `false`).
2. Ràng buộc bảo vệ tuyệt đối: Cờ này **CHỈ** được phép có hiệu lực trong `kProfileMode` và **BẮT BUỘC BỊ TẮT / VÔ HIỆU HOÁ** trong `kReleaseMode` (`if (kReleaseMode) allowTestAdsInProfileForStaging = false`).
3. Nhờ đó, đội ngũ kỹ thuật có thể chạy `flutter run --profile` hoặc cài đặt `app-profile.apk` lên Google Pixel 7 Pro để thu thập heap dump sạch, đo PSS chuẩn và đo khung hình gfxinfo mà không vi phạm policy trong release.

## Acceptance Criteria

- [ ] `AdConfig.allowTestAdsInProfileForStaging` mặc định là `false`.
- [ ] Trong `kReleaseMode`, cờ này bị vô hiệu hóa hoàn toàn, không thể bật bằng bất kỳ cách nào.
- [ ] Trong `kProfileMode`, khi cờ được bật chủ ý, `_testIdFootgunBlocked` không chặn test ad IDs, cho phép nạp ad bình thường để benchmark.
- [ ] Chạy thành công benchmark RAM và gfxinfo trên Profile build trên Google Pixel 7 Pro.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra ma trận hành vi của cờ trong các chế độ `debug`, `profile`, `release`.
- **Widget test:** Kiểm tra `BannerAdWidget` nạp thành công ở profile mode khi cờ bật.
- **Integration test & Smoke test:** Chạy benchmark trên Pixel 7 Pro thật ở profile mode, xuất báo cáo PSS và Jank frames sạch.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T258 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/config/ad_config.dart, lib/src/core/ad_manager.dart.
2. Viết test trước để chứng minh hạn chế hiện tại (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
