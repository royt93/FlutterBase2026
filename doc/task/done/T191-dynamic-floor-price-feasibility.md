# T191 — Tự đặt "giá tối thiểu" cho quảng cáo (NGHIÊN CỨU KHẢ THI, CHƯA CHẮC LÀM ĐƯỢC)

**Loại:** exclusive-feature (idea, khả thi chưa rõ)
**Ưu tiên:** P3 (chỉ nghiên cứu)
**Trạng thái:** todo (research-only, KHÔNG code)
**Nguồn phát hiện:** agy
**Quyết định chủ dự án (2026-09-08):** Chỉ tìm hiểu khả thi trước (KHÔNG hứa làm)

## Ý tưởng
Tự đặt "giá tối thiểu" cho mỗi quảng cáo (không bán rẻ hơn giá này — dynamic floor price / bid targeting). Vấn đề: việc này thường phải làm trên trang quản lý web của Google/AppLovin (không phải trong code chạy trên điện thoại), nên nhiều khả năng SDK này KHÔNG TỰ LÀM ĐƯỢC ý này ở tầng Flutter wrapper.

## Việc cần làm (CHỈ nghiên cứu — KHÔNG code)
1. Tìm hiểu API chính thức của `google_mobile_ads` và `applovin_max` (package Dart đang dùng) — có API nào cho phép set floor price / targeting theo request không? Đọc kỹ tài liệu chính thức, không đoán.
2. Tìm hiểu cơ chế mediation waterfall thật của AdMob Mediation/AppLovin MAX — floor price thường được cấu hình ở cấp "ad unit"/"waterfall" trên dashboard, không phải per-request từ client. Xác nhận đúng/sai giả định này.
3. Nếu có API client-side nào cho phép ảnh hưởng (dù gián tiếp, VD custom targeting keywords/extras gửi kèm request), ghi rõ khả năng và giới hạn của nó.
4. Kết luận rõ ràng: khả thi hoàn toàn / khả thi một phần (nêu rõ phần nào) / không khả thi ở tầng SDK này.

## Prompt để chạy (giai đoạn nghiên cứu)
```
Nghiên cứu: package google_mobile_ads và applovin_max (bản đang pin trong packages/ad_sdk/pubspec.yaml) có API nào cho phép SDK client-side đặt "floor price"/giá sàn hoặc ảnh hưởng bid targeting theo từng request quảng cáo không? Đọc tài liệu chính thức, changelog, và source code của 2 package này (không đoán, không suy diễn). Xác nhận: floor price trong mediation waterfall của AdMob Mediation/AppLovin MAX có thực sự chỉ cấu hình được trên dashboard web (Ad Manager/AppLovin dashboard) hay có API client-side nào không. Nếu có API custom targeting/extras gửi kèm request (dù không trực tiếp là "floor price"), ghi rõ khả năng thực tế và giới hạn. Viết kết luận rõ ràng vào file task T191 này, KHÔNG viết code, KHÔNG hứa hẹn tính năng nếu chưa xác nhận chắc chắn khả thi.
```

## Tín hiệu kết thúc (KHÔNG code, KHÔNG push code)
Dừng khi đã điền đầy đủ mục "Kết luận nghiên cứu" bên dưới với: khả thi/không khả thi + bằng chứng cụ thể (trích dẫn tài liệu/API). Nếu kết luận là "khả thi một phần" hoặc "khả thi", chuyển thành 1 task mới (số ID kế tiếp) với đầy đủ template loop-fix chuẩn trước khi bắt đầu code — không code trực tiếp trong file nghiên cứu này.

## Kết luận nghiên cứu (2026-09-13)

**Kết luận: KHÔNG khả thi ở tầng SDK Flutter này.** Đã đọc source code
thật của 2 package đang pin (`google_mobile_ads: ^7.0.0`,
`applovin_max: ^4.6.4`, ở `~/.pub-cache`) + tài liệu chính thức qua
WebFetch/WebSearch, không đoán.

### AdMob (`google_mobile_ads`)

Đọc toàn bộ `AdRequest` class (`lib/src/ad_containers.dart`) trong
package thật — KHÔNG có field nào tên `floorPrice`/`bidFloor` hay tương
đương. Chỉ có `extras` (`Map<String, String>?`) — dùng cho "mediation
extras" (network-specific runtime tweak, VD tắt tiếng audio của 1
network cụ thể — xem `mediation_extras.dart`), yêu cầu viết thêm code
NATIVE Android/iOS (implement `MediationNetworkExtrasProvider`/
`FLTMediationNetworkExtrasProvider`) — không thể làm thuần Dart. Tài
liệu chính thức
(developers.google.com/admob/flutter/mediation/network-specific-parameters)
xác nhận cơ chế này dùng cho tinh chỉnh HÀNH VI, không có gợi ý nào về
floor price.

**Xác nhận đúng giả định gốc**: floor price của AdMob (in-app bidding)
được cấu hình ở cấp ad unit/mediation group, trên trang quản lý web
AdMob — không có API client-side nào (Flutter hay native) để đặt/đổi
theo từng request.

### AppLovin (`applovin_max`)

`AppLovinMAX.setExtraParameter(key, value)` (có thật trong package,
`applovin_max.dart` dòng ~274) — gửi 1 cặp key-value tuỳ ý lên server
AppLovin. Đây là cơ chế CÓ THẬT, nhưng KHÔNG có tài liệu chính thức nào
xác nhận có key nào trong đó điều khiển được bid floor (đã tìm kiếm kỹ,
không thấy danh sách key nào của AppLovin công bố `setExtraParameter`
điều khiển được floor price).

**Cơ chế THẬT SỰ để đổi bid floor của AppLovin MAX**: "Ad Unit
Management API"
(support.applovin.com/en/max/advanced-features/ad-unit-management-api)
— đã xác nhận qua WebFetch: đây là **REST API PHÍA SERVER**, gọi bằng
HTTP (`POST` tới `https://o.applovin.com/mediation/v1/ad_unit/<id>` với
field `bid_floors`), xác thực bằng **Management Key riêng** (khác hẳn
SDK key dùng trong app — tài liệu ghi rõ: key này lấy từ "Account >
General > Keys", dùng cho mục đích quản trị/server-side, KHÔNG PHẢI để
nhúng vào app di động).

**Đây chính là lý do KHÔNG khả thi, không chỉ "chưa có API" mà còn RỦI
RO BẢO MẬT NGHIÊM TRỌNG nếu cố làm**: nhúng Management Key vào app di
động (để gọi API này từ trong app) tương đương với việc nhúng 1 khoá quản
trị tài khoản AppLovin vào APK/IPA — ai decompile app cũng lấy được, có
thể chiếm quyền chỉnh sửa toàn bộ cấu hình ad unit của tài khoản. Đây
đúng loại rủi ro giống hệt vụ `android/app/private_key.pepk` từng bị
commit nhầm vào repo này (ghi trong CLAUDE.md mục "Known pending
security debt").

### Kết luận cuối

Không khả thi ở tầng SDK Flutter — cả 2 network đều thiết kế floor
price là cấu hình PHÍA SERVER/DASHBOARD có chủ đích, không phải tham số
runtime client gửi kèm mỗi request quảng cáo. Với AppLovin, API thật sự
tồn tại nhưng đòi hỏi 1 credential không bao giờ được đưa vào code chạy
trên máy người dùng — làm task này đúng nghĩa sẽ tự tạo ra 1 lỗ hổng bảo
mật, không chỉ là 1 tính năng khó làm. Không chuyển thành task code —
giữ nguyên "không khả thi" theo đúng điều kiện dừng của task này.

**Nguồn tham khảo** (qua WebSearch/WebFetch, 2026-09-13):
- support.applovin.com/en/max/advanced-features/ad-unit-management-api
- developers.google.com/admob/flutter/mediation/network-specific-parameters
- Source code thật: `google_mobile_ads-7.0.0/lib/src/ad_containers.dart`,
  `mediation_extras.dart`; `applovin_max-4.6.4/lib/applovin_max.dart`

## Đóng task (2026-09-15)

Chủ dự án xác nhận: **không khả thi, đóng**. Kết luận nghiên cứu ở trên ("Không khả thi ở tầng SDK Flutter") là kết luận cuối — không chuyển thành task code, đóng theo đúng điều kiện dừng ban đầu của task này.
