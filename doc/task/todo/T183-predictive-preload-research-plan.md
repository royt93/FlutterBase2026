# T183 — Dự đoán thói quen người dùng để nạp trước quảng cáo thông minh hơn (NGHIÊN CỨU, CHƯA CODE)

**Loại:** idea (thử nghiệm)
**Ưu tiên:** P2 (nghiên cứu)
**Trạng thái:** todo (research-only, KHÔNG code ngay)
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Nên rã task vào backlog, ghi kế hoạch — CHƯA code, chỉ lập plan trước

## Ý tưởng
SDK tự "học" thói quen người dùng để đoán trước lúc nào họ sắp muốn xem quảng cáo có thưởng, rồi nạp sẵn trước đó — giúp quảng cáo hiện nhanh hơn khi họ bấm xem. Đây là ý tưởng chưa chắc chắn hiệu quả, cần thử nghiệm thật mới biết.

## Liên hệ hạ tầng đã có
SDK đã có `JourneyPrefetcher` (`packages/ad_sdk/lib/src/monetization/journey_prefetcher.dart`) — theo dõi "signal" (route/sự kiện) và thời gian trung bình tới lúc show quảng cáo (`_timeToShow` rolling average) cho từng cặp signal+type. Đây CHÍNH LÀ nền tảng gần nhất để mở rộng thành "dự đoán thói quen" — không cần xây từ đầu.

## Rủi ro / đánh đổi
- Cần dữ liệu đủ lớn (nhiều lần dùng) mới "học" có ý nghĩa — người dùng mới cài app sẽ không có lợi ích gì ngay.
- Nạp trước sai lúc = tốn tài nguyên/tiền quảng cáo (mỗi lần nạp trước tốn 1 request) mà không ai xem — cần cân bằng giữa lợi ích "nạp nhanh hơn" và chi phí "nạp thừa".
- Độ phức tạp code tăng, khó test đầy đủ mọi kịch bản hành vi người dùng.

## Việc cần làm (CHỈ giai đoạn nghiên cứu — KHÔNG code)
1. Đọc kỹ `JourneyPrefetcher` hiện tại, xác định chính xác nó ĐANG làm gì (rolling average thời gian, không phải machine learning) và giới hạn của nó.
2. Đề xuất bản kế hoạch: thuật toán cụ thể nào khả thi trong 1 SDK client-side, không cần backend (VD: rolling average nâng cao hơn, đếm tần suất theo giờ trong ngày, Markov chain đơn giản giữa các route) — so sánh effort vs lợi ích của từng cách.
3. Đề xuất cách đo lường hiệu quả thật (A/B test nội bộ? so sánh thời gian chờ trước/sau?).
4. Viết kết luận vào mục "Kết luận nghiên cứu" bên dưới: có nên làm tiếp không, thuật toán nào, effort ước tính.

## Prompt để chạy (giai đoạn nghiên cứu)
```
Đọc kỹ packages/ad_sdk/lib/src/monetization/journey_prefetcher.dart và test/journey_prefetcher_test.dart để hiểu đúng cơ chế hiện tại (rolling average thời gian giữa signal và show event). KHÔNG code tính năng mới. Viết 1 bản kế hoạch (design doc) ngắn gọn trả lời: (1) thuật toán "dự đoán thói quen" nào khả thi để mở rộng từ JourneyPrefetcher hiện có mà không cần backend/ML phức tạp, (2) effort ước tính (số ngày/tuần), (3) cách đo hiệu quả thật sau khi làm, (4) rủi ro cụ thể. Cập nhật kết luận vào file task T183 này (mục "Kết luận nghiên cứu"), không tạo file mới, không sửa code SDK.
```

## Tín hiệu kết thúc (KHÔNG code, KHÔNG push code)
Dừng khi đã điền đầy đủ mục "Kết luận nghiên cứu" bên dưới với: thuật toán đề xuất, effort ước tính, cách đo hiệu quả, rủi ro. KHÔNG commit code mới, chỉ cập nhật chính file này. Chờ chủ dự án đọc và quyết định có chuyển thành task code thật (task mới, số ID kế tiếp) hay không.

## Kết luận nghiên cứu
(để trống, điền sau khi nghiên cứu xong)
