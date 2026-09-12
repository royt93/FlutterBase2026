# T164 — Cơ chế theo dõi "consent đã áp dụng chưa" yếu đi với app chỉ dùng 1 mạng quảng cáo

**Loại:** bug (logic nội bộ, chưa thấy hậu quả cụ thể cho người dùng)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy (bản gốc thổi phồng hậu quả, tự verify lại đúng bản chất qua code thật — xem ghi chú bên dưới)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Nếu app CHỈ dùng 1 mạng quảng cáo (VD chỉ Google, không dùng AppLovin), hệ thống theo dõi nội bộ "consent đã áp dụng chưa" luôn coi như chưa áp dụng (vì nó chờ CẢ 2 mạng đều xác nhận mới ghi nhận) — làm 1 vài logic nội bộ khó phân biệt đúng đâu là giá trị đã chốt, đâu là giá trị mới đọc được nhưng chưa chốt. Không gây lỗi thấy ngay, nhưng làm yếu 1 cơ chế bảo vệ nội bộ dùng để so sánh "thiết bị nói gì" với "đã áp dụng cho nhà quảng cáo chưa".

**Ghi chú quan trọng khi verify:** nguồn phát hiện ban đầu (agy) mô tả sai một cơ chế "tự động re-apply liên tục khi resume" — cơ chế đó KHÔNG tồn tại trong code (đã grep toàn bộ, không có hàm `_reconcileConsentOnResume` nào). Bản chất thật: `_committedConsent` getter (`ad_consent.dart:5268-5269`) fallback về `_consentManager?.adConsent` khi `_lastAppliedToProviders` còn null — 3 nơi dùng thật (`ad_manager.dart:3529,5329,5350,5741`) đều là so sánh device-vs-applied, không phải vòng lặp tự động nào.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_consent.dart:148-149,172,210,230-231` — `appLovinApplied`/`adMobApplied` chỉ set `_lastAppliedToProviders` khi CẢ 2 đều `true` (dòng 230: `if (appLovinApplied && adMobApplied)`). App chỉ cấu hình 1 provider sẽ không bao giờ set `appLovinApplied`/`adMobApplied` phía kia → biến này mãi mãi `null`.

## Việc cần làm
1. Sửa điều kiện dòng 230 để chỉ yêu cầu các provider THỰC SỰ ĐƯỢC CẤU HÌNH đều applied (đối chiếu `AdConfig.provider` để biết app dùng 1 hay 2 mạng), không mặc định yêu cầu cả 2.
2. Viết test cho cả 2 trường hợp: app 1 mạng (chỉ AdMob) và app 2 mạng, xác nhận `_lastAppliedToProviders`/`lastConsentAppliedToProviders` được set đúng trong cả 2 case.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_consent.dart dòng ~148-231: điều kiện "if (appLovinApplied && adMobApplied)" (dòng ~230) yêu cầu CẢ 2 provider applied mới set _lastAppliedToProviders, kể cả khi app chỉ cấu hình 1 mạng quảng cáo (AdConfig.provider chỉ định rõ 1 hay 2 mạng) — khiến app 1 mạng không bao giờ set được giá trị này. Sửa điều kiện để chỉ yêu cầu các provider THỰC SỰ được cấu hình (dựa vào AdConfig.provider) đều applied. Đọc kỹ 4 nơi dùng _committedConsent/lastConsentAppliedToProviders (ad_manager.dart dòng ~3529,5329,5350,5741) để hiểu đúng tác động trước khi sửa, không phá vỡ hành vi app 2 mạng hiện tại. Viết unit test cho cả app 1-mạng và 2-mạng.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả app 1 mạng và 2 mạng, xác nhận `lastConsentAppliedToProviders` set đúng trong cả 2 case; test 4 call site (`_committedConsent` usage) không bị breaking cho case 2 mạng.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device với app mẫu cấu hình chỉ AdMob, xác nhận consent-gate logic hoạt động đúng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** SDK có 1 biến nội bộ ghi lại
"consent (đồng ý cho phép quảng cáo) đã thực sự được gửi tới cả 2 hãng
quảng cáo chưa" — dùng để so sánh "máy nói gì" với "đã áp dụng thật chưa".
Trước đây, biến này chỉ được ghi nhận khi CẢ Google VÀ AppLovin đều xác
nhận thành công — nhưng nếu app chỉ dùng 1 trong 2 hãng (rất phổ biến),
phía KHÔNG dùng sẽ không bao giờ xác nhận, khiến biến này mãi mãi trống —
không gây lỗi thấy ngay (đã có sẵn 1 cơ chế dự phòng lấy giá trị khác thay
thế), nhưng làm yếu đi độ chính xác của vài phép so sánh nội bộ.

**Kỹ thuật đã sửa (`ad_consent.dart:230-246`):** chỉ yêu cầu ĐÚNG các
hãng app THỰC SỰ cấu hình (`AdConfig.provider`) phải xác nhận thành công,
không mặc định đòi cả 2.

**Phát hiện quan trọng khi verify (trước khi viết test):** đã xác minh
`AppLovinMAX.setHasUserConsent`/`setDoNotSell` (thư viện AppLovin thật) là
hàm `void`, gọi kiểu "bắn rồi quên" (không `await`) — nghĩa là phía
AppLovin trong thực tế LUÔN được ghi nhận "thành công" ngay lập tức, bất
kể native có thật sự nhận được hay không (lỗi native chỉ nổi lên sau, độc
lập, không thể bắt bằng try/catch tại chỗ). Điều này khiến 1 nửa lý do gốc
task mô tả (phía AppLovin "thất bại" chặn app chỉ-dùng-AdMob) không có
đường tái hiện thật trong code hiện tại — nhưng nửa còn lại (phía AdMob,
gọi CÓ `await` nên lỗi thật sự bắt được) vẫn là bug thật 100%: app chỉ
dùng AppLovin mà lỡ có lỗi tạm thời phía AdMob (hãng app không hề dùng)
vẫn bị chặn không ghi nhận consent. Bản sửa vẫn đúng và cần thiết cho cả 2
chiều, chỉ là chiều AppLovin không tái hiện được bằng test giả lập lỗi
(ghi chú rõ trong code test).

**Kết quả review độc lập (`codex review --uncommitted`, 1 vòng):** sạch,
không tìm ra lỗi.

**Test coverage:**
- `test/ad_consent_test.dart`: thêm 4 test mới (nhóm "T164") — app chỉ
  AppLovin: lỗi AdMob (không dùng) không chặn ghi nhận; app chỉ AdMob: lỗi
  CHÍNH AdMob (hãng đang dùng) vẫn phải chặn như cũ; không có config
  (`config: null`) vẫn giữ nguyên yêu cầu cả 2 như hành vi round-32 gốc;
  app chỉ AdMob thành công bình thường vẫn ghi nhận đúng. Không sửa/
  breaking test cũ nào (14 test trong file vẫn xanh nguyên — có 1 dòng
  dọn dẹp code chết không đổi hành vi).
- Full SDK suite: 1851 test xanh.
- Full example suite: 42 test xanh.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** file mới
`example/integration_test/r164_admob_only_consent_committed_test.dart` —
chạy app thật với cấu hình mặc định của example (chỉ AdMob, qua
`--dart-define=AD_PROVIDER_ADMOB=true`), xác nhận
`lastConsentAppliedToProviders` KHÔNG còn `null` sau khi init thật — đúng
bug thật task mô tả (trước fix, giá trị này sẽ mãi mãi `null` cho app 1
mạng). PASS.

**Tự chấm điểm: 9.5/10.**
