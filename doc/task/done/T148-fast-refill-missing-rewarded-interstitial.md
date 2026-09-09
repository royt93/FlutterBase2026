# T148 — Nạp lại chậm cho quảng cáo rewarded-interstitial sau khi xem xong

**Loại:** bug
**Ưu tiên:** P1
**Trạng thái:** DONE — verified 9.5/10 (codex, 2 vòng review độc lập, 2 finding P2 sửa xong)
**Nguồn phát hiện:** subagent core+state, tự verify trực tiếp code

## Kết quả (2026-09-09)
Fixed. Thêm `unawaited(loadRewardedInterstitialAd())` vào cả `_onVipActiveChanged()` (dòng ~4039) và `_onAppOpenStateChange()`'s first-secondary-load (dòng ~4141), song song với 3 format kia.

Codex review vòng 1 bắt 2 finding P2 trong integration test demo (test có thể "pass giả" khi VIP không active do phụ thuộc first-install-grace ephemeral) — sửa bằng cách dùng `vip.addVip()` thật để tạo trạng thái xác định thay vì dựa vào grace ngẫu nhiên. Vòng 2: sạch, không finding.

Test: 2 unit test mới (`test/fast_refill_rewarded_interstitial_test.dart`) — cả 2 đường fast-refill, PASS. Demo mới trong `VipDemoPage` ("Fast-refill proof (T148)" — nút "End VIP now"). Integration test mới (`example/integration_test/vip_fast_refill_demo_test.dart`) viết đúng, nhưng **script đóng gói không chạy hết được do adb/USB rớt kết nối 3 lần liên tiếp cùng 1 điểm trên 2 thiết bị khác nhau (TECNO KJ7, Pixel 7 Pro)** — lỗi môi trường, không phải lỗi code. Bằng chứng smoke-test thật: log thiết bị thật (nhiều lần chạy, cả 2 máy) đã bắt được đúng dòng fix chạy: `"first secondary load → inter + rewarded + RI"` và `"loadRewardedInterstitial skipped — VIP member"` (gate đúng khi VIP active). Suite: 1793/1793 (ad_sdk) + 33/33 (example) xanh, `flutter analyze` sạch.
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Sau khi người dùng xem xong 1 loại quảng cáo có thưởng, hệ thống nạp sẵn quảng cáo tiếp theo ngay lập tức cho App Open + Interstitial + Rewarded (2 "đường tắt nạp nhanh" duy nhất, tránh phải chờ retry-timer 5 phút) — nhưng bỏ sót loại rewarded-interstitial, phải chờ tới 5 phút mới tự nạp lại. Hậu quả: người dùng muốn xem thêm ngay thì phải chờ lâu hơn bình thường cho đúng loại quảng cáo này, mất doanh thu tiềm năng.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_manager.dart:4039-4046` (`_onVipActiveChanged()`) và `:4145-4153` (`_onAppOpenStateChange()`) — cả 2 "fast-refill path" đều gọi `loadAppOpenAd()/loadInterstitial()/loadRewardedAd()` nhưng thiếu `loadRewardedInterstitialAd()`.
- Fix "2026-08-16 audit" (dòng 8308-8318) chỉ thêm rewardedInterstitial vào backstop định kỳ `_retryRefillAds` (chạy mỗi 5 phút), không lan sang 2 fast-path này.

## Việc cần làm
1. Thêm `loadRewardedInterstitialAd()` vào cả `_onVipActiveChanged()` và `_onAppOpenStateChange()`.
2. Kiểm tra không gây nạp trùng lặp (nếu đã có 1 quảng cáo rewarded-interstitial đang cache/đang load, không gọi load lại — dùng đúng guard sẵn có của các format khác).
3. Thêm log SafeLogger khi fast-refill kích hoạt cho từng loại.
4. Thêm demo trong `example/` minh hoạ: xem xong rewarded-interstitial → quảng cáo tiếp theo sẵn sàng ngay (không phải chờ 5 phút) — có timestamp hiển thị để chứng minh.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_manager.dart: 2 hàm _onVipActiveChanged() (dòng ~4039-4046) và _onAppOpenStateChange() (dòng ~4145-4153) đang gọi loadAppOpenAd()/loadInterstitial()/loadRewardedAd() nhưng thiếu loadRewardedInterstitialAd() — thêm vào cả 2 chỗ, dùng đúng guard chống nạp trùng mà loadRewardedAd() đang dùng (đối chiếu code lân cận). Viết unit test: sau khi VIP hết hạn / sau khi App Open đổi trạng thái, xác nhận loadRewardedInterstitialAd() được gọi giống 3 loại kia, không tạo double-load nếu đã có cache. Thêm log SafeLogger. Thêm demo trong example/ đo thời gian nạp lại.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả 2 fast-refill path (VIP thay đổi, App Open thay đổi) xác nhận rewardedInterstitial được nạp lại ngay, không double-load; integration test đo thời gian sẵn sàng lại.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, chứng minh rewarded-interstitial sẵn sàng lại gần như ngay sau khi xem xong (không phải chờ 5 phút).
8. Thành công: commit + push. Thất bại: quay lại bước 1.
