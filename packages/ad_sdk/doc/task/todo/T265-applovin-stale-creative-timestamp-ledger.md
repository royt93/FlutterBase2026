# T265 — Quản Lý Hạn Dùng Quảng Cáo AppLovin MAX Bằng Sổ Cái Thời Gian (Stale Creative Timestamp Ledger)

- **Loại:** Enhancement / Revenue Integrity
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Theo chính sách của các mạng quảng cáo:
- Google AdMob có cơ chế tự động kiểm tra quảng cáo đã nạp có quá 4 giờ hay không; nếu quá 4 giờ, quảng cáo được coi là hết hạn (stale) và không được phép phát để tránh hiển thị nội dung lỗi thời và mất doanh thu.
- Ngược lại, plugin `applovin_max` không công khai timestamp thời điểm nạp của creative quảng cáo.
- Nếu người dùng để ứng dụng chạy nền nhiều giờ liền rồi mở lại, quảng cáo AppLovin nạp từ 5-6 tiếng trước vẫn có thể bị đem ra phát. Điều này dẫn đến nguy cơ nhà quảng cáo từ chối trả tiền cho lượt hiển thị đó (unmonetized impression).

## Đề xuất giải pháp

1. Trong `AppLovinAdapter`, khi callback `onAdLoaded` được kích hoạt cho bất kỳ slot toàn màn hình nào (Interstitial, Rewarded, App Open):
   - Ghi lại mốc thời gian nạp `_creativeLoadedTimestamp = DateTime.now()`.
2. Khi hàm `show...` được gọi:
   - Kiểm tra `DateTime.now().difference(_creativeLoadedTimestamp) > Duration(hours: 4)`.
   - Nếu quảng cáo đã quá 4 tiếng, tự động đánh dấu slot là hết hạn (`AdSlot.markExpired()`), hủy creative cũ, và tự động gửi request nạp một creative mới toanh trước khi cho phép hiển thị.

## Acceptance Criteria

- [ ] Quảng cáo AppLovin tồn kho quá 4 tiếng không bao giờ bị phát cho người dùng.
- [ ] Tự động nạp lại creative mới khi phát hiện quảng cáo cũ hết hạn.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Dùng `fakeAsync` tua thời gian 4 giờ 1 phút, kiểm tra hàm `showInterstitialAd` từ chối phát và kích hoạt nạp lại.
- **Integration test:** Chạy self-check trên thiết bị thật, kiểm tra log ghi nhận thời gian tồn kho của creative.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T265 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/adapters/applovin_adapter.dart, lib/src/state/ad_slot.dart.
2. Viết test trước để kiểm tra cơ chế hủy ad quá hạn của AppLovin (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
