# T39 — SSV (server-side verification) plumbing có sẵn nhưng chưa wire vào host/example

- **REQ:** 3 (ad type reward — không bắt buộc theo 7 yêu cầu gốc, nhưng liên quan tới tính đầy đủ)
- **Priority:** P2 · **Severity:** LOW (tính năng optional, không phá hành vi hiện tại) · **Status:** 📋 todo — **cần quyết định từ partner, không phải bug**
- **Files:** `packages/ad_sdk/lib/src/ad_manager.dart` (dòng ~1617-1627, `ssvCustomData`/`ssvUserId`), test: `reward_ssv_test.dart`

## Vấn đề (Why)
SSV cho rewarded ads (khác hoàn toàn với VIP-by-code — đây là cơ chế chuẩn của AdMob/AppLovin để đối tác tự verify reward ở server riêng của họ, SDK không tự chạy hay verify gì) đã có plumbing đầy đủ và test pass (`reward_ssv_test.dart`, 401 dòng), nhưng **chưa được host app hoặc example wire thật** — `ssvCustomData`/`ssvUserId` hiện luôn `null`. Tính năng "trơ", không ảnh hưởng hành vi hiện tại, chỉ cần kích hoạt khi có server thật.

## Việc cần làm (không phải fix code, mà là quyết định + cấu hình)
- Hỏi partner: có cần SSV cho rewarded ads trong app hiện tại không? (Thường chỉ cần khi có currency/reward có giá trị thật cần chống gian lận phía server.)
- Nếu cần: cấu hình postback URL trên AdMob/AppLovin dashboard, sau đó truyền `ssvCustomData`/`ssvUserId` thật khi gọi `showRewardedAd`.
- Nếu không cần: đóng task này là "intentionally not used", không cần code thay đổi.

## Acceptance criteria
- [ ] Có quyết định rõ ràng (dùng hay không dùng SSV) ghi lại trong `doc/feature.md`.
- [ ] Nếu dùng: `ssvCustomData`/`ssvUserId` được truyền thật từ host app, có postback URL cấu hình đúng trên dashboard.
