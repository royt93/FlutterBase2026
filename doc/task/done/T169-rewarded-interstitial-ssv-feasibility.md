# T169 — Kiểm tra khả thi: chống gian lận phía server cho rewarded-interstitial

**Loại:** enhancement (research-gate, chỉ làm nếu khả thi)
**Ưu tiên:** P2
**Trạng thái:** done (nghiên cứu xong, không code — xem "Kết luận nghiên cứu")
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

**Đã kiểm tra:** đọc trực tiếp source code của package `google_mobile_ads` bản `7.0.0` (đúng bản đang pin trong `pubspec.yaml`), tại `.pub-cache/hosted/pub.dev/google_mobile_ads-7.0.0/lib/src/ad_containers.dart`.

**Kết quả kiểm tra kỹ thuật:** Google **CÓ** hỗ trợ đầy đủ. `RewardedInterstitialAd` có hàm `setServerSideOptions(ServerSideVerificationOptions options)` giống hệt `RewardedAd` (dòng 1364-1367 và 1269-1272 trong file trên). Vậy về mặt kỹ thuật, việc thêm SSV cho rewarded-interstitial hoàn toàn làm được.

**Nhưng phát hiện thêm 1 điều quan trọng khi đọc code:** lý do rewarded-interstitial hiện chưa có SSV **không phải** vì Google chưa hỗ trợ — mà là 1 quyết định thiết kế có chủ đích từ trước (đánh dấu "T89" trong code, file `packages/ad_sdk/lib/src/core/ad_provider_adapter.dart` dòng 306-315):

> SSV dùng để backend của app xác minh 1 hành động CHỦ ĐỘNG của người dùng ("tôi đã xem quảng cáo này để nhận thưởng này"). Rewarded-interstitial là loại quảng cáo TỰ ĐỘNG hiện ra ở điểm chuyển màn hình (VD: giữa 2 màn chơi), người dùng không hề chủ động bấm "xem quảng cáo để nhận thưởng" trước đó — nên tín hiệu xác minh này sẽ yếu hơn, dễ khiến backend của app tin tưởng sai vào 1 tín hiệu không thực sự đáng tin.

**Đã hỏi và chủ dự án quyết định (2026-09-12): KHÔNG thêm SSV cho rewarded-interstitial** — giữ nguyên quyết định T89, vì lý do sản phẩm ở trên vẫn còn hợp lý, không phải giới hạn kỹ thuật cần "sửa".

**Việc đã làm:** chỉ nghiên cứu + ghi lại kết luận vào file này. Không sửa code, không thêm test, không commit code, không push code — đúng theo "Tín hiệu kết thúc" của task này khi kết quả nghiên cứu không dẫn tới việc code mới.

**Tự chấm điểm phần nghiên cứu: 9.5/10** — đã đọc đúng source code của đúng phiên bản package đang dùng (không đoán/không chỉ tin theo tài liệu chung chung), tìm ra lý do thật (khác với lý do task ban đầu đoán), hỏi lại chủ dự án trước khi tự ý đóng hoặc tự ý code thêm.
