# T28 — Privacy Options host entry point

- **REQ:** 6, 7
- **Priority:** P1 · **Severity:** HIGH · **Status:** done
- **Nguồn:** `doc/audit/audit_gemini.md` §3.2 — gap được audit ghi nhận nhưng chưa từng ticket hoá
- **Files:** `packages/ad_sdk/lib/src/vip/vip_redeem_screen.dart`, `packages/ad_sdk/example/lib/main.dart`, `lib/mckimquyen/widget/vip/vip_screen.dart`, `lib/translations/en_us.dart`, `lib/translations/vi_vn.dart`, `packages/ad_sdk/test/vip_redeem_screen_test.dart`

## Vấn đề (Why)

T06 (done) đã ship `AdManager().showPrivacyOptions()` / `isPrivacyOptionsRequired()` ở tầng SDK, kèm README mục "Privacy Options entry point" khuyến nghị host đặt nút thường trực. Nhưng host app (`vip_screen.dart`) chưa từng gọi `showPrivacyOptions()` — chỉ wiring `onPrivacyPolicyTap` (mở link Privacy Policy tĩnh), không có lối vào nào để user *đổi lại* lựa chọn consent (GDPR yêu cầu re-consent phải luôn khả dụng, không chỉ đọc chính sách một lần).

## Fix

1. `vip_redeem_screen.dart`: thêm `privacyOptions` string vào `VipRedeemStrings` và `onPrivacyOptionsTap` (`VoidCallback?`) vào `VipRedeemScreen`, mirror hệt pattern `privacyPolicy`/`onPrivacyPolicyTap` sẵn có. Footer gate mở rộng để hiện khi **một trong hai** callback non-null; `_buildFooter()` render cả hai nút trong `Wrap` (mỗi nút chỉ hiện khi callback tương ứng non-null).
2. Host `vip_screen.dart`: `onPrivacyOptionsTap: () => AdManager().showPrivacyOptions()`, `privacyOptions: 'vip_privacy_options'.tr`.
3. Translation key `vip_privacy_options` thêm vào `en_us.dart`/`vi_vn.dart`.
4. SDK example app (`main.dart` — `VipRedeemScreen(...)` trong "VIP / redeem" `DemoTile`) wiring song song, giữ bất biến "host và example render cùng 1 screen".

## Acceptance criteria
- [x] `VipRedeemScreen` có `onPrivacyOptionsTap` optional, không breaking API cũ (footer vẫn ẩn khi cả hai callback null).
- [x] Host `vip_screen.dart` gọi `AdManager().showPrivacyOptions()` từ nút footer — có lối vào GDPR re-consent bền vững.
- [x] Example app parity giữ nguyên.
- [x] Test mới trong `test/vip_redeem_screen_test.dart` (+2): footer ẩn/hiện đúng theo `onPrivacyOptionsTap`, tap gọi đúng callback.
- [x] `flutter analyze` sạch (SDK + host), test SDK (402/402) + host root xanh.
