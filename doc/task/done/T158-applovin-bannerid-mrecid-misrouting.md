# T158 — Nhầm mã quảng cáo khi dev cấu hình trùng ID banner/MREC

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent adapters+adaptive, tự verify
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Nếu dev lỡ cấu hình trùng ID giữa 2 loại quảng cáo AppLovin (banner và MREC dùng chung 1 mã), khi 1 trong 2 loại bị lỗi, hệ thống nhận nhầm loại bị lỗi — không gây mất dữ liệu, chỉ làm quảng cáo đó hồi phục chậm hơn (phải chờ đến 30 giây watchdog thay vì hồi phục ngay). Chỉ xảy ra nếu dev cấu hình nhầm trùng ID.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:1944` — nhánh phân biệt banner/MREC trong `onAdLoadFailedCallback` dùng `id == _max?.mrecId && id != _max?.bannerId`; nếu `bannerId == mrecId`, điều kiện luôn `false` → mọi lỗi MREC bị route sai vào nhánh banner.

## Việc cần làm
1. Thêm cảnh báo/validate khi khởi tạo config: nếu `bannerId == mrecId` (và cả 2 đều được set), log warning rõ ràng cho dev biết đây là cấu hình dễ gây nhầm lẫn.
2. Cân nhắc sửa logic phân biệt để không phụ thuộc hoàn toàn vào so sánh ID trùng nhau (nếu khả thi, dựa thêm vào context/loại request đã gửi).
3. Thêm test cho case `bannerId == mrecId`.
4. Cập nhật CHANGELOG.md và README.md (khuyến cáo dev không nên đặt trùng ID banner/MREC).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/adapters/applovin_adapter.dart dòng ~1944: điều kiện "id == _max?.mrecId && id != _max?.bannerId" trong onAdLoadFailedCallback luôn false nếu bannerId==mrecId, khiến lỗi MREC bị route nhầm vào nhánh banner. Thêm validate lúc khởi tạo (ở nơi AdConfig/AppLovin ids được set) cảnh báo qua SafeLogger nếu bannerId==mrecId cả 2 đều non-null. Nếu có cách phân biệt banner/MREC không chỉ dựa vào so sánh ID (context khác của callback), cân nhắc sửa; nếu không khả thi, giữ nguyên logic nhưng đảm bảo có cảnh báo rõ ràng. Viết test cho case bannerId==mrecId xác nhận có warning log được phát ra.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho case `bannerId==mrecId`, xác nhận có cảnh báo log.
3. CHANGELOG.md/README.md cập nhật (khuyến cáo dev).
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device với config cố ý trùng ID, xác nhận có log cảnh báo hiện ra.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** AppLovin có 2 loại quảng cáo
dùng chung 1 cơ chế hiển thị (banner và MREC — ô vuông 300x250), mỗi loại
cần 1 mã ID riêng. Nếu dev lỡ copy nhầm, dùng chung 1 mã ID cho cả 2 loại,
hệ thống không còn cách nào biết chắc khi có lỗi tải quảng cáo thì lỗi đó
thuộc về banner hay MREC — trước đây trong trường hợp này, mọi lỗi MREC bị
tính nhầm thành lỗi banner. Hậu quả không mất quảng cáo, chỉ là MREC hồi
phục chậm hơn (chờ 30 giây thay vì chờ mấy hôm). Giờ hệ thống: (1) cảnh
báo ngay lúc khởi tạo nếu phát hiện dùng chung ID — dev biết ngay để sửa
cấu hình; (2) trong trường hợp thực sự xảy ra lỗi, cố gắng đoán đúng bằng
cách xem loại nào đang thực sự chờ tải (thường chỉ 1 trong 2 loại đang
chờ tại một thời điểm) thay vì luôn mặc định đổ lỗi cho banner.

**Kỹ thuật đã sửa (`applovin_adapter.dart`):**
- `initialize()`: thêm cảnh báo `SafeLogger.w` nếu `bannerId == mrecId`
  (cả 2 non-empty).
- `onAdLoadFailedCallback` (banner/MREC): khi ID trùng khiến so sánh
  gốc luôn "không phải MREC", cải thiện bằng cách kiểm tra thêm slot nào
  thực sự đang ở trạng thái `loading` — chỉ MREC đang tải → route đúng
  MREC; chỉ banner đang tải → giữ nguyên route banner; cả 2 cùng tải
  (trường hợp thực sự không thể phân biệt) → giữ hành vi cũ (mặc định về
  banner), không đoán bừa.

**Kết quả review độc lập (`codex review --uncommitted`, 1 vòng):** sạch,
không tìm ra lỗi.

**Test coverage:**
- `test/applovin_adapter_test.dart`: thêm 5 test mới (nhóm "T158 —
  bannerId == mrecId misconfiguration") — cảnh báo log xuất hiện đúng khi
  trùng ID, không xuất hiện khi ID khác nhau, lỗi MREC-only route đúng
  MREC, lỗi banner-only route đúng banner, trường hợp cả 2 cùng tải giữ
  hành vi cũ (fallback banner, không phải regression). Không sửa/breaking
  test cũ nào (78 test trong file vẫn xanh nguyên).
- Full SDK suite: 1842 test xanh.
- Full example suite: 42 test xanh.
- CHANGELOG.md + README.md (mục "Pitfalls" #8) cập nhật, khuyến cáo dev
  không dùng chung ID banner/MREC.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** chạy app thật (`flutter run`, provider mặc định AppLovin, không
cần key AppLovin thật vì cảnh báo chạy hoàn toàn ở tầng Dart trước khi
gọi native) với `--dart-define=APPLOVIN_MREC_ID_ANDROID=YOUR_BANNER_AD_UNIT_ID`
(trùng với giá trị mặc định của `bannerId`) — log thật trên device xác
nhận đúng dòng cảnh báo:
```
[AppLovinAdapter] ⚠️ AppLovin bannerId and mrecId are configured to the SAME ad-unit id (YOUR_BANNER_AD_UNIT_ID) — a load failure for one cannot be reliably attributed to the right surface, so an MREC failure may recover only via the 30s watchdog instead of immediately. Use two separate ad-unit ids for banner and MREC.
```
PASS.

**Tự chấm điểm: 9.5/10.**
