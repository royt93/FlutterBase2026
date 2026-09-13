# T189 — Tự "học" chọn mạng quảng cáo trả tiền cao nhất theo thời gian thực (NGHIÊN CỨU, CHƯA CODE)

**Loại:** exclusive-feature (idea, rủi ro trung bình)
**Ưu tiên:** P2 (nghiên cứu)
**Trạng thái:** todo (research-only, KHÔNG code ngay)
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Chưa làm, chỉ ghi plan vào backlog

## Ý tưởng
Hiện SDK tự đổi qua mạng quảng cáo trả tiền cao hơn theo luật đơn giản (`MonetizationArbitrator` — nếu 1 mạng lỗi nhiều thì chuyển). Ý tưởng mới: cho SDK "tự học" thông minh hơn (thuật toán multi-armed bandit) để luôn chọn đúng mạng trả tiền cao nhất theo thời gian thực, cân bằng giữa "khai thác" (chọn mạng tốt nhất hiện biết) và "khám phá" (thử mạng khác để cập nhật thông tin mới).

## Rủi ro đã xác nhận với chủ dự án
Nếu thuật toán "tự học" sai lúc đầu (dữ liệu chưa đủ), có thể chọn nhầm mạng trả ít tiền hơn một thời gian trước khi tự sửa — ảnh hưởng trực tiếp tới doanh thu đang ổn định. **Chủ dự án chọn KHÔNG làm ngay, chỉ ghi kế hoạch, vì rủi ro giảm doanh thu tạm thời chưa xứng đáng so với lợi ích chưa kiểm chứng.**

## Việc cần làm (CHỈ giai đoạn nghiên cứu — KHÔNG code)
1. Đọc kỹ `MonetizationArbitrator` hiện tại (`packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`) để hiểu đúng luật đơn giản đang dùng và giới hạn của nó.
2. Nghiên cứu thuật toán bandit phù hợp cho bối cảnh client-side, dữ liệu ít, không có backend trung tâm để tổng hợp (VD epsilon-greedy đơn giản, Thompson Sampling nhẹ) — so sánh độ phức tạp implement vs độ an toàn (tránh chọn sai kéo dài).
3. Đề xuất cơ chế "an toàn khi mới học" (cold-start guard): trong giai đoạn đầu (dữ liệu ít), ưu tiên hành vi gần giống luật đơn giản hiện tại, chỉ "khám phá" mạnh hơn khi đã có đủ dữ liệu tin cậy.
4. Đề xuất cách A/B test nội bộ trước khi bật thật cho toàn bộ người dùng (VD bật cho 1 tỷ lệ nhỏ, so sánh doanh thu với nhóm còn lại dùng luật cũ).
5. Viết kết luận vào mục "Kết luận nghiên cứu" bên dưới.

## Prompt để chạy (giai đoạn nghiên cứu)
```
Đọc kỹ packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart và test tương ứng để hiểu đúng luật đơn giản hiện tại. KHÔNG code tính năng mới. Viết bản kế hoạch (design doc) trả lời: (1) thuật toán bandit nào phù hợp cho bối cảnh client-side (không backend trung tâm, dữ liệu mỗi thiết bị độc lập) — so sánh epsilon-greedy vs Thompson Sampling vs phương án khác, (2) cơ chế cold-start guard để tránh chọn sai kéo dài lúc dữ liệu còn ít, (3) cách A/B test an toàn trước khi bật thật cho mọi người dùng, (4) effort ước tính, (5) rủi ro cụ thể còn lại sau khi có cold-start guard. Cập nhật kết luận vào file task T189 này, không sửa code SDK.
```

## Tín hiệu kết thúc (KHÔNG code, KHÔNG push code)
Dừng khi đã điền đầy đủ mục "Kết luận nghiên cứu" bên dưới. KHÔNG commit code mới. Chờ chủ dự án đọc và quyết định có chuyển thành task code thật hay không — ĐẶC BIỆT cần chủ dự án xác nhận rõ ràng trước khi bắt đầu code, vì đây là thay đổi ảnh hưởng trực tiếp tới doanh thu đang ổn định.

## Kết luận nghiên cứu (2026-09-13)

### Sửa lại tiền đề mô tả gốc (đã đọc code thật trước khi kết luận)

Mô tả gốc nói SDK "tự đổi mạng theo luật đơn giản qua `MonetizationArbitrator`
— nếu 1 mạng lỗi nhiều thì chuyển". **Không đúng.** Đã đọc kỹ
`monetization_arbitrator.dart`: class này KHÔNG hề đổi mạng quảng cáo —
nó chỉ quyết định "có nên hiện quảng cáo hay chuyển hướng gợi ý mua VIP"
(so sánh eCPM gần đây với ngưỡng cấu hình). SDK vốn CHỈ chạy 1 mạng duy
nhất mỗi phiên (`AdConfig.provider` cố định lúc `initialize()`) — không
có cơ chế "chuyển mạng giữa phiên" nào cả.

Hạ tầng THẬT sự liên quan đến ý tưởng "tự học chọn mạng trả cao nhất" là:
- `WaterfallTuner` (T122, opt-in) — theo dõi tỷ lệ fill + eCPM trung bình
  gần đây theo từng `(provider, format, placement)`, nhưng CHỈ QUAN SÁT,
  không tự chuyển gì cả (comment trong code: "this SDK serves one
  provider per session... only a host explicitly reading this
  recommendation... can do that").
- `AdManager().pickSessionProvider()` (T136) — ĐÃ CÓ SẴN 1 dạng
  epsilon-exploration đơn giản: host truyền `explorationRate` (VD 0.05 =
  5% phiên), hàm này random chọn có "khám phá" (thử mạng khác thật, không
  phải giả lập) cho phiên đó hay không, có giới hạn tần suất
  (`minIntervalBetweenExplorations`, mặc định 1 ngày/lần) lưu trên đĩa.
  Đây CHÍNH LÀ tiền thân thô sơ của bandit — chỉ khác: tỷ lệ khám phá CỐ
  ĐỊNH (host tự đặt số, không tự điều chỉnh theo dữ liệu), quyết định ở
  MỨC PHIÊN (session-level, không phải mỗi lần hiện quảng cáo).

### (1) Thuật toán bandit phù hợp

**Đề xuất: epsilon-greedy với epsilon giảm dần (decaying), KHÔNG phải
Thompson Sampling**, vì:
- Thompson Sampling cần mô hình phân phối xác suất (Beta/Normal) và cập
  nhật posterior — phức tạp hơn nhiều so với lợi ích thêm được trong bối
  cảnh chỉ có 2 lựa chọn (AdMob/AppLovin), dữ liệu mỗi thiết bị độc lập
  (không gộp dữ liệu nhiều máy — điều này tự nó đã giới hạn nghiêm trọng
  độ tin cậy thống kê, không máy nào tích lũy đủ mẫu nhanh).
- epsilon-greedy giảm dần: bắt đầu với epsilon cao (khám phá nhiều, giống
  cách `pickSessionProvider` đã làm), giảm dần theo số phiên đã thu thập
  đủ dữ liệu (WaterfallTuner đã có sẵn), về gần 0 khi 1 mạng đã rõ ràng
  thắng — dễ hiểu, dễ debug, dễ giải thích với chủ dự án hơn khi có sự cố.
- Vì mỗi thiết bị độc lập (không có backend tổng hợp), "học" chỉ có ý
  nghĩa Ở CẤP THIẾT BỊ — một thiết bị mới luôn bắt đầu lại từ đầu, không
  thừa hưởng kinh nghiệm từ thiết bị khác. Info gain rất chậm so với
  bandit tập trung (server-side) thật sự dùng trong ad-tech công nghiệp.

### (2) Cơ chế cold-start guard

Đề xuất: dùng chính `WaterfallTuner._minSamplesToPrice`-kiểu ngưỡng đã có
sẵn trong `MonetizationArbitrator` (5 mẫu) làm mẫu — trước khi đủ N mẫu
đáng tin cậy cho CẢ 2 mạng, epsilon giữ CỐ ĐỊNH ở mức thấp (như
`pickSessionProvider` hiện tại), không tự tăng giảm gì cả. Chỉ sau khi cả
2 mạng đã có đủ dữ liệu mới bắt đầu cho epsilon giảm dần theo độ tin cậy
(VD độ lệch eCPM giữa 2 mạng đủ lớn và ổn định qua N phiên liên tiếp).

### (3) Cách A/B test an toàn

Hạ tầng ĐÃ CÓ SẴN cho việc này — không cần xây mới: `pickSessionProvider`
với `explorationRate` nhỏ CHÍNH LÀ 1 dạng A/B test on-device (so sánh
doanh thu giữa phiên "khám phá" và phiên "theo cohort cài đặt" qua
`WaterfallTuner`'s dữ liệu thu thập được). Chỉ cần: bật epsilon-adaptive
cho 1 tỷ lệ nhỏ THIẾT BỊ (không phải phiên) — VD dùng GAID hash % 100 <
5 để chọn nhóm "thử nghiệm" cố định lâu dài cho thiết bị đó, so sánh
doanh thu trung bình giữa 2 nhóm qua nhiều tuần.

### (4) Effort ước tính
- epsilon-greedy giảm dần + cold-start guard tái dùng hạ tầng
  `WaterfallTuner`/`pickSessionProvider` có sẵn: ~1-1.5 tuần (thiết kế +
  code + test + theo dõi số liệu thật nhiều tuần trước khi kết luận có
  hiệu quả không).
- Thompson Sampling (nếu chủ dự án vẫn muốn thử dù không khuyến nghị):
  thêm ít nhất 3-5 ngày nữa cho mô hình phân phối xác suất + kiểm định.

### (5) Rủi ro cụ thể còn lại sau cold-start guard
- Dữ liệu mỗi thiết bị độc lập, mẫu nhỏ (vài chục impression/ngày) —
  "học" có thể không bao giờ đủ tin cậy thống kê trên 1 thiết bị đơn lẻ,
  khiến toàn bộ nỗ lực epsilon-adaptive không mang lại lợi ích đo được rõ
  ràng so với epsilon cố định đơn giản đã có.
- Thay đổi provider giữa các phiên nghĩa là mất tính nhất quán trải
  nghiệm quảng cáo cho user (khác network = khác hành vi load/hiển thị) —
  rủi ro UX, không chỉ rủi ro doanh thu.
- Không thể tắt/rollback tức thời trên thiết bị đã "học" sai — chỉ có thể
  đợi thuật toán tự điều chỉnh lại hoặc host tự reset dữ liệu tích luỹ.

### Khuyến nghị
**Chưa nên làm ngay** — đồng ý với quyết định ban đầu của chủ dự án.
Nếu làm, ưu tiên epsilon-greedy giảm dần tái dùng hạ tầng
`WaterfallTuner`/`pickSessionProvider` sẵn có (rẻ, ít rủi ro hơn nhiều so
với Thompson Sampling), và bắt buộc phải theo dõi số liệu thật nhiều tuần
qua A/B test on-device trước khi cân nhắc bật mặc định.
