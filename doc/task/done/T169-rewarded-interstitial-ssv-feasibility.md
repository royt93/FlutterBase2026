# T169 — Kiểm tra khả thi: chống gian lận phía server cho rewarded-interstitial

**Loại:** enhancement (research-gate, chỉ làm nếu khả thi)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent adapters+adaptive
**Quyết định chủ dự án (2026-09-08):** Kiểm tra khả thi trước, rồi làm nếu được

## Vấn đề (giải thích thực tế)
1 loại quảng cáo có thưởng đặc biệt (rewarded-interstitial) đang thiếu 1 tùy chọn chống gian lận phía server (SSV — Server-Side Verification) mà loại thường đã có. Chưa chắc chắn Google có hỗ trợ tùy chọn này cho đúng loại quảng cáo này hay không — cần kiểm tra trước khi hứa làm.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:1708-1710` (rewarded-interstitial, không có `ssvCustomData`/`ssvUserId`) vs `:1439-1440` (rewarded thường, có).

## Việc cần làm (CHỈ giai đoạn 1 — nghiên cứu, không code ngay)
1. Đọc tài liệu chính thức `google_mobile_ads` (package Dart) xem `RewardedInterstitialAd`/`ServerSideVerificationOptions` có được hỗ trợ như `RewardedAd` không — kiểm tra changelog/API reference đúng version package đang dùng trong `pubspec.yaml`.
2. Nếu package HỖ TRỢ: chuyển task này thành công việc thật — thêm `ssvCustomData`/`ssvUserId` vào `showRewardedInterstitial`, đối xứng với `showRewarded`, viết đủ test.
3. Nếu package KHÔNG hỗ trợ: đóng task, ghi rõ lý do (giới hạn từ Google, không phải giới hạn SDK này) vào file này, cập nhật README.md phần "Known limitations" nếu cần.

## Prompt để chạy (giai đoạn nghiên cứu)
```
Kiểm tra: package google_mobile_ads (bản đang pin trong packages/ad_sdk/pubspec.yaml) có hỗ trợ ServerSideVerificationOptions cho RewardedInterstitialAd giống RewardedAd không? Tìm trong source code của package (thư mục .pub-cache hoặc pub.dev changelog/API docs đúng version). Nếu CÓ hỗ trợ: sửa packages/ad_sdk/lib/src/adapters/admob_adapter.dart để showRewardedInterstitial (dòng ~1708-1710) nhận ssvCustomData/ssvUserId giống showRewarded (dòng ~1439-1440), viết đủ unit test đối xứng với rewarded thường, thêm demo trong example/, cập nhật CHANGELOG.md. Nếu KHÔNG hỗ trợ: dừng lại, cập nhật đúng file task T169 này với kết luận + lý do kỹ thuật cụ thể (trích dẫn version/API), không tự chế giải pháp thay thế.
```

## Tín hiệu kết thúc
- Nếu khả thi: áp dụng đầy đủ tín hiệu kết thúc loop chuẩn (analyze sạch, test 100%, unit+widget+integration đủ case, log, demo, CHANGELOG, audit >9/10, smoke test thật, rồi push).
- Nếu không khả thi: dừng ở bước kết luận nghiên cứu, KHÔNG code, KHÔNG push — chỉ cập nhật file này với kết luận rõ ràng.

## Kết luận nghiên cứu
(để trống, điền sau khi kiểm tra xong)
