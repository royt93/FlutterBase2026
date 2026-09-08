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
