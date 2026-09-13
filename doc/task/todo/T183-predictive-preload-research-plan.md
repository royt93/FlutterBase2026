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

## Kết luận nghiên cứu (2026-09-13)

### Cơ chế hiện tại (đã đọc kỹ `journey_prefetcher.dart`)

`JourneyPrefetcher` hiện tại là 1 rolling average ĐƠN GIẢN, KHÔNG phải
machine learning: mỗi cặp (signal, loại quảng cáo) giữ tối đa 10 mẫu thời
gian gần nhất từ lúc `notifySignal()` gọi tới lúc quảng cáo đó thật sự
được show (`_timeToShow`, cửa sổ trượt 10 mẫu). Quyết định nạp trước hay
không chỉ dựa vào: "trung bình 10 lần gần nhất có vượt `maxHoldDuration`
không". Toàn bộ dữ liệu này SỐNG TRONG BỘ NHỚ (`Map` thường), **mất hết
khi tắt app** — nghĩa là "thói quen" hiện tại chỉ học được TRONG 1 PHIÊN
sử dụng, không tích lũy qua nhiều ngày/tuần như ý tưởng ban đầu mong
muốn.

### Đề xuất thuật toán khả thi (không cần backend/ML)

**Đề xuất chính — lưu lại rolling average qua nhiều phiên (persist)**:
Ghi `_timeToShow` xuống `SharedPreferences` (giống cách
`AdSafetyConfig`/`AdPreferences` đã làm với các bộ đếm khác), đọc lại lúc
khởi tạo `JourneyPrefetcher`. Đây là thay đổi NHỎ về code (thêm đọc/ghi
prefs ở 2 chỗ: constructor + sau mỗi lần cập nhật `_timeToShow`) nhưng
là cải tiến CÓ Ý NGHĨA NHẤT — biến "học trong 1 phiên" (dữ liệu quá ít,
gần như vô dụng cho user mới mở app hôm nay) thành "học qua nhiều
ngày" (đúng tinh thần "dự đoán thói quen" ban đầu).

**Đề xuất phụ — thêm độ tin cậy (confidence) dựa trên phương sai**: hiện
tại chỉ dùng trung bình cộng (mean), không nhìn độ lệch (variance). Nếu
10 mẫu gần nhất dao động quá lớn (VD: 5 giây, 5 phút, 30 giây, 10 phút...
xen kẽ), trung bình cộng vô nghĩa — nên thêm điều kiện "chỉ tin trung
bình nếu độ lệch chuẩn không quá X% so với trung bình", nếu không thì coi
như "chưa đủ tin cậy" và fallback về hành vi mặc định (nạp sớm, an toàn).
Đây là cải tiến nhỏ, tính toán ngay trên dữ liệu đã có sẵn (không cần
lưu thêm), effort thấp.

**Đã cân nhắc nhưng KHÔNG đề xuất ngay**: học theo giờ trong ngày (time-
of-day bucket) hoặc Markov chain nhiều bước — cả 2 đều cần hạ tầng phức
tạp hơn nhiều (timer chủ động thay vì bị động theo signal, hoặc theo dõi
chuỗi nhiều signal thay vì 1) mà lợi ích chưa rõ ràng hơn 2 đề xuất trên
— để dành cho vòng nghiên cứu sau nếu 2 đề xuất chính chứng minh hiệu quả
thật.

### Effort ước tính
- Persist rolling average qua session: ~2-3 ngày (code + test unit +
  test tích hợp qua thật sự tắt/mở lại app + migrate an toàn nếu có data
  cũ dạng khác).
- Confidence dựa trên phương sai: ~1 ngày (tính toán thêm trên dữ liệu
  sẵn có, không cần lưu trữ mới).
- Tổng: ~1 tuần làm việc (bao gồm test + device smoke + tài liệu), nếu
  làm cả 2 đề xuất.

### Cách đo hiệu quả thật
SDK không có analytics/A-B test built-in cho tính năng nội bộ này — cần
host tự đo qua `AdShowEvent`/`AdLoadEvent` đã có sẵn (SDK có thể emit
thêm 1 field/event mới kiểu "ad đã sẵn sàng bao lâu trước khi user bấm
xem" để host tự so sánh trước/sau khi bật tính năng persist). Cách thực
tế nhất: so sánh 2 nhóm cohort theo version app (trước/sau khi phát hành
bản có persist) qua chỉ số "% lần show mà quảng cáo đã sẵn sàng ngay lập
tức" — không phải A/B test song song thật sự (vì cùng 1 SDK, không dễ
chạy 2 biến thể cùng lúc trên cùng thiết bị).

### Rủi ro cụ thể
- Riêng tư: dữ liệu lưu lại chỉ là khoảng thời gian (duration), không
  phải nội dung hành vi cụ thể — nhưng vẫn nên nói rõ trong tài liệu SDK
  rằng tính năng này lưu dữ liệu thời gian cục bộ trên máy, để host biết
  khi viết chính sách riêng tư của họ.
- Thói quen người dùng có thể đổi theo thời gian (user chơi game nhiều
  hơn vào cuối tuần, ít hơn ngày thường) — rolling average đơn giản có
  thể "học chậm" theo thay đổi này; cần cân nhắc giảm trọng số dữ liệu cũ
  (decay) nếu muốn chính xác hơn — nhưng đó là độ phức tạp thêm, không
  đề xuất ngay ở giai đoạn 1.
- Khó đo "hiệu quả thật" nếu host không tự làm thêm phân tích riêng — SDK
  chỉ có thể cung cấp dữ liệu thô, không tự chứng minh được ROI.

### Khuyến nghị
**Nên làm tiếp** — nhưng CHỈ đề xuất "persist qua session" trước (rẻ,
lợi ích rõ ràng, rủi ro thấp); để "confidence theo phương sai" và các ý
tưởng phức tạp hơn (time-of-day, Markov chain) lại cho vòng sau nếu vòng
1 chứng minh hiệu quả thật qua dữ liệu host cung cấp.
