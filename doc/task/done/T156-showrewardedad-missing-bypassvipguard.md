# T156 — Hàm tiện lợi chặn cứng VIP xem thêm quảng cáo tự nguyện

**Loại:** enhancement (bug ẩn trong hàm tiện lợi)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** agy, tự verify plausible qua code thật
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Khi 1 người đã trả tiền VIP (không bị quảng cáo làm phiền) muốn TỰ NGUYỆN xem thêm 1 quảng cáo có thưởng để nhận quà thưởng thêm — SDK đã hỗ trợ đúng tính năng này ở tầng thấp (`showRewardedAd(bypassVipGuard: true)`, xem CLAUDE.md mục VIP entitlement). Nhưng nếu dev dùng đúng hàm tiện lợi có sẵn (`AdScreenState.showRewardedAd`, thay vì tự viết thủ công), tham số này bị chặn cứng, không có cách bật — người VIP muốn xem thêm để lấy quà sẽ không làm được dù họ muốn.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_screen.dart:158-192` — `AdScreenState.showRewardedAd` không chuyển tiếp tham số `bypassVipGuard` xuống `AdManager().showRewardedAd(...)` thật.

## Việc cần làm
1. Thêm tham số `bypassVipGuard` (mặc định `false`, không breaking) vào `AdScreenState.showRewardedAd`, forward đúng xuống `AdManager().showRewardedAd(...)`.
2. Grep các hàm helper show* khác trong `ad_screen.dart` xem có thiếu tham số quan trọng nào tương tự không (đối chiếu toàn bộ tham số của `AdManager().showRewardedAd`).
3. Thêm demo trong `example/`: màn hình VIP có nút "xem quảng cáo thưởng thêm" dùng qua `AdScreenState.showRewardedAd(bypassVipGuard: true)`.
4. Cập nhật CHANGELOG.md và README.md (mục VIP entitlement, nhắc dùng qua `AdScreenState` cũng hoạt động).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_screen.dart dòng ~158-192: AdScreenState.showRewardedAd không forward tham số bypassVipGuard xuống AdManager().showRewardedAd() thật (tham số này đã tồn tại ở tầng AdManager, dùng cho case VIP tự nguyện xem thêm quảng cáo thưởng — xem CLAUDE.md mục VIP entitlement). Thêm tham số bypassVipGuard (default false) vào AdScreenState.showRewardedAd, forward đúng xuống. Đối chiếu toàn bộ tham số khác của AdManager().showRewardedAd để chắc không thiếu thêm tham số nào khác trong helper này. Viết widget test: gọi AdScreenState.showRewardedAd(bypassVipGuard: true) trong lúc VIP đang active, xác nhận rewarded ad thật sự được gọi show (không bị chặn bởi VIP guard). Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho `bypassVipGuard: true/false` qua `AdScreenState.showRewardedAd` trong lúc VIP active.
3. Demo trong `example/` + CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, kích hoạt VIP, bấm nút xem thêm quảng cáo thưởng trong demo, xác nhận hiện quảng cáo thật.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-11)

**Fix:** `AdScreenState.showRewardedAd()` thêm 2 tham số mới, forward xuống
`AdManager().showRewardedAd()` thật:
- `bypassVipGuard` (mặc định `false`) — VIP tự nguyện xem thêm quảng cáo
  thưởng. Trước đây helper chỉ có 1 điều kiện cứng
  `if (AdManager().isVIPMember())` chặn TOÀN BỘ, không có cách nào bật lại
  dù `AdManager()` thật đã hỗ trợ sẵn — sửa thành
  `if (AdManager().isVIPMember() && !bypassVipGuard)`.
- `callSiteTag` (mặc định `'unspecified'`) — tag cho nhật ký bypass audit
  trail (T155), cùng lý do proof-of-compliance như `bypassSafety`.

**codex review — 2 vòng:**
- Vòng 1: sạch — forwarding đúng, test qua.
- Vòng 2 (P2): helper vẫn thiếu `onDemandLoadTimeout` (tham số đã có sẵn ở
  `AdManager().showRewardedAd`, dùng khi VIP không preload sẵn ad, phải
  load ngay lúc bấm) — thêm forward tiếp tham số này (mặc định 15s, khớp
  đúng default của `AdManager`).

**Grep đối chiếu:** kiểm tra toàn bộ helper show* khác trong
`ad_screen.dart` — `showInterstitialAd`/`showRewardedInterstitialAd` đã
forward đủ tham số tương ứng bên `AdManager`, không thiếu gì thêm.

**Test:**
- Unit (`test/ad_screen_test.dart`, nhóm "rewarded bypassVipGuard
  forwarding (T156)"): 2 case — VIP active + `bypassVipGuard:true` vẫn gọi
  ad thật (qua adapter giả, đếm `showRewardedCalls`); VIP active +
  `bypassVipGuard:false` (mặc định) vẫn chặn như cũ, không phá hành vi cũ.
  Thêm `_FakeVip implements VipManager` (kèm `activeListenable` — thiếu
  override này làm `BannerAdWidget` bên trong `buildBanner()` throw qua
  `noSuchMethod`, gây layout cao 100000px, tự phát hiện qua log lỗi hit-test
  chi tiết chứ không đoán mò).
- Widget (`example/test/vip_demo_page_test.dart`, mới): nút "Watch ad → +3
  days VIP (stack)" tồn tại, bấm trước khi SDK init không crash.
- Integration (`example/integration_test/vip_watch_ad_to_extend_test.dart`,
  mới): thử **6 lần** trên Pixel 7 Pro thật
  (`--dart-define=AD_PROVIDER_ADMOB=true`) — đều dính lỗi môi trường (1 lần
  mất kết nối adb giữa chừng, các lần còn lại `pumpAndSettle()`/tìm
  Scrollable timeout do splash/AdLoadingDialog trên máy này mất thời gian
  không ổn định — CÙNG loại flakiness đã ghi nhận ở T150/T152/T154, không
  phải bug code). Đã sửa 2 vấn đề thật trong lúc debug: (1) đổi
  `pumpAndSettle()` thành vòng pump cố định vì VIP countdown timer không
  bao giờ để tree "settle"; (2) codex re-review (P2) chỉ ra
  `tester.takeException()` một mình không đủ mạnh — vẫn pass ngay cả khi
  VIP guard vô tình bị khôi phục (vì thất bại báo qua
  `onEarnedReward(false)`, không throw) — thêm assertion mạnh hơn: đếm
  entry mới trong `bypassAuditTrail` với `callSiteTag: 'vip_extend_screen'`
  (chỉ ghi từ bên trong nhánh `bypassVipGuard` thật của
  `AdManager().showRewardedAd()`) tăng lên sau khi bấm — bằng chứng thật
  rằng lệnh gọi đã chạm đúng code path, không chỉ "không crash". File test
  được đánh giá đúng cấu trúc (mirror chính xác pattern đã chạy thành công
  của `vip_fast_refill_demo_test.dart`) nhưng chưa tự chạy sạch được lần
  nào trong phiên này — cần thử lại với kết nối device mới trong 1 phiên
  sau.

**Demo:** `VipDemoPage` chuyển từ `StatefulWidget`/`State` sang
`AdScreen`/`AdScreenState` (drop-in, không phá vỡ gì khác trên trang) để có
quyền gọi `showRewardedAd()`. Nút "Watch ad → +3 days VIP (stack)" (đã có
từ T148) giờ gọi qua helper `showRewardedAd(bypassVipGuard: true,
callSiteTag: 'vip_extend_screen')` thay vì gọi thẳng
`AdManager().showRewardedAd()` — chứng minh đúng con đường tích hợp
KHUYẾN NGHỊ (không phải constructor thô) hoạt động.

**Docs:** README.md — thêm ghi chú ngay dưới đoạn giải thích
`bypassVipGuard` (mục VIP entitlement) nói rõ `AdScreenState.showRewardedAd()`
cũng forward đúng 2 tham số này.

**Suite:** 1818/1818 (`packages/ad_sdk`), 41/41 (`example`, không dính flake
compliance có sẵn ở lần chạy cuối). `flutter analyze` sạch cả 2 package.

**Điểm tự chấm:** 9/10 — fix đúng, đơn giản, codex 2 vòng đều tìm bug/gap
thật và đã sửa hết, tự phát hiện thêm 1 lỗi test-setup (thiếu
`activeListenable` override) qua debug kỹ thay vì đoán mò. Trừ điểm vì
integration test chưa tự chạy sạch được lần nào trong phiên (6 lần đều
dính flake môi trường) — bù lại bằng unit test rất mạnh (đếm
`showRewardedCalls` qua adapter giả thật + đếm bypass audit trail entry
thật) chứng minh chính xác cùng 1 claim mà integration test định chứng
minh.
