# T219 — Đa ngôn ngữ (i18n) cho dialog/widget/feature/helper của SDK

**Loại:** new-feature (kiến trúc)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** user request (2026-09-13)

## Vấn đề (giải thích thực tế)

SDK hiện có UI hiển thị trực tiếp cho người dùng cuối (consent dialog, CCPA
opt-out toggle, VIP redeem screen, debug overlay, ...). App host tích hợp
SDK có thể có người dùng nói nhiều ngôn ngữ khác nhau, nhưng SDK hiện chỉ
cung cấp string tiếng Việt làm preset mặc định, không có preset tiếng Anh
hay ngôn ngữ khác, và không tự động theo locale máy.

## Hiện trạng đã audit (2026-09-13)

Pattern "host tự cấp string qua 1 class" đã tồn tại cho 3 nơi:
- `ConsentDialogStrings` (`lib/src/consent/consent_dialog_strings.dart`) —
  chỉ có preset `.vi`.
- `CcpaOptOutStrings` (`lib/src/consent/ccpa_opt_out_strings.dart`) — chỉ
  có preset `.vi`.
- `VipDialogStrings` (`lib/src/vip/vip_dialog_strings.dart`) — không có
  preset nào, host phải tự điền toàn bộ field.

Các widget/feature khác (banner, native, MREC, debug overlay
`DebugAdOverlay`, các demo trong `example/`) hiển thị text hard-code tiếng
Anh trực tiếp trong code, không đi qua bất kỳ string-class nào.

## Việc cần làm (đề xuất, cần bàn kỹ trước khi code — dùng brainstorming
skill hoặc hỏi lại nếu chưa rõ)

1. Quyết định kiến trúc: giữ pattern "string class do host cấp" (nhất
   quán với 3 class hiện có, không cần thêm dependency) hay chuyển sang
   `intl`/ARB (chuẩn Flutter, nhưng thêm dependency + build step).
2. Nếu giữ string-class: thêm preset `.en` (và có thể `.vi`, `.en` là 2
   preset tối thiểu) cho cả 3 class hiện có; xác định nơi nào KHÁC trong
   SDK hiển thị text cho end-user (không phải log dev) cần string-class
   tương tự (debug overlay của SDK — nếu end-user thấy được — không phải
   demo trong example/, vì example/ là code mẫu của host, không phải SDK).
3. Cân nhắc auto-detect locale máy (`Localizations.localeOf(context)`)
   làm fallback khi host không cấu hình rõ, thay vì luôn mặc định `.vi`.
4. KHÔNG đổi API hiện có theo cách breaking — mọi preset mới là bổ sung,
   field/class hiện có giữ nguyên.

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho mỗi preset ngôn ngữ mới + test không breaking cho preset
   `.vi` hiện có.
3. Widget test xác nhận dialog/UI thật render đúng preset được chọn.
4. README.md cập nhật mục hướng dẫn đa ngôn ngữ.
5. Audit độc lập (codex review --uncommitted), chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, đổi preset ngôn ngữ, xác nhận UI
   hiển thị đúng.
8. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-15)

**Chủ dự án chọn (AskUserQuestion):** giữ pattern "string class do host
cấp", thêm preset `.en` (không chuyển sang intl/ARB — không thêm
dependency/build step).

**Đã làm:**

- `ConsentDialogStrings`, `CcpaOptOutStrings`, `VipDialogStrings`: mỗi
  class thêm `static const X en = X();` (đặt tên tường minh cho default
  hiện có, vốn đã LÀ tiếng Anh — sửa 1 hiểu nhầm trong "Hiện trạng đã
  audit" gốc của task: task nói "không có preset tiếng Anh" nhưng thực ra
  default constructor value của cả 3 class từ trước đã là tiếng Anh, chỉ
  là không có TÊN preset `.en` để gọi tường minh) + `static X resolve([Locale? locale])`
  (chọn `.vi` cho locale 'vi', `.en` cho mọi locale khác; không truyền
  tham số → fallback `PlatformDispatcher.instance.locale`, dùng được cả
  trước khi có widget nào build, ví dụ ngay trong `main()`).
- `VipDialogStrings` thêm MỚI preset `.vi` (trước đây class này không có
  preset nào — tiếng Việt chỉ tồn tại dưới dạng ví dụ copy-paste trong doc
  comment; nay là preset thật, có test).
- **Phát hiện giữa chừng (không có trong "Hiện trạng đã audit" gốc của
  task):** `VipRedeemStrings` (`lib/src/vip/vip_redeem_screen.dart`) —
  1 class RIÊNG, ~30 field (nút, nhãn, snack message...) cho TOÀN màn
  hình redeem VIP thật (`VipRedeemScreen`, không phải debug tool), khác
  hẳn `VipDialogStrings` (chỉ 8 field, cho dialog xác nhận nhỏ). Class
  này trước đây KHÔNG có preset `.en`/`.vi`/resolve() nào cả. Hỏi lại chủ
  dự án qua AskUserQuestion — chọn gộp vào T219 luôn thay vì tách task
  riêng. Đã dịch đầy đủ ~30 field (bao gồm 5 field dạng hàm tham số hoá:
  `expiresAt`/`remainingDays`/`remainingHours`/`remainingExtraHours`/
  `activeEntries`, mỗi hàm cần 1 static function riêng vì default value
  của `const` constructor phải là compile-time constant — không dùng
  được lambda inline).
- Đã kiểm tra `DebugAdOverlay` (`kDebugMode`-only, xác nhận qua code thật
  `lib/src/widget/debug_ad_overlay.dart:138`) và `RevenuePanel`
  (`kDebugMode`-only, `lib/src/widget/revenue_panel.dart:25`) — cả 2 đều
  KHÔNG bao giờ hiển thị cho end-user thật (chỉ dev debug build), đúng
  như checklist mục 2 của task yêu cầu xác nhận — không cần i18n.
- Không đổi API hiện có theo cách breaking: mọi field/class cũ giữ
  nguyên giá trị mặc định.
- README.md: cập nhật mục "Consent & compliance" với ví dụ `.en`/`.vi`/
  `resolve()` cho cả 4 class, và ghi rõ DebugAdOverlay/RevenuePanel nằm
  ngoài phạm vi vì lý do gì.
- CHANGELOG.md: 1 mục `[Unreleased]` mới.
- Example app: trang demo mới `I18nPresetDemoPage` (nút chuyển EN/VI,
  hiển thị sống Consent dialog + CCPA toggle + VIP dialog strings preview
  + nút mở VIP redeem screen thật) — tile mới trên HomePage.

**Test:**
- Unit (`test/i18n_localised_strings_test.dart`, 18 test): `.en` giống hệt
  default hiện có (không breaking), `.vi` đúng nội dung, `resolve()` đúng
  cho locale 'vi'/khác, cho cả 4 class.
- Widget (cùng file): `showConsentDialog`/`CcpaOptOutToggle`/
  `VipRedeemScreen` thật render đúng text của preset được truyền vào
  (không phải chỉ kiểm tra field string suông).
- Example: `example/test/i18n_preset_demo_page_test.dart` (4 test) +
  `home_page_test.dart` (1 test nav mới) — chuyển đổi EN/VI trên trang
  demo thật render lại đúng text CCPA/VIP/consent dialog/VIP redeem
  screen.
- Integration thật trên **thiết bị Android thật** (Samsung, serial
  `R58MA6WYRPE`) — `example/integration_test/t219_i18n_preset_test.dart`:
  chạy app thật, mở trang demo T219, xác nhận text tiếng Anh mặc định,
  chuyển sang Tiếng Việt, xác nhận text tiếng Việt THẬT hiển thị trên màn
  hình thiết bị thật. **PASS.** Không test riêng `VipRedeemStrings` trên
  device (đã test qua widget test đầy đủ + cùng cơ chế `resolve()` y hệt
  3 class kia đã test trên device — lặp lại không thêm tín hiệu mới).
- Verify non-vacuous (revert-and-confirm-red-restore): làm cho cả
  `ConsentDialogStrings.resolve()` và `VipRedeemStrings.resolve()` — cả
  2 lần revert đều làm test fail đúng như kỳ vọng, restore lại pass.

**Kết quả test toàn bộ:**
- `flutter test` (SDK): 2127/2127 pass (từ 2109 sau T217 + api_golden,
  +18 cho i18n test mới, đã bù trừ qua các bước golden regenerate).
- `flutter test` (example): 63/63 pass.
- `flutter analyze`: sạch cả 2 package.
- API golden test (`test/api_golden_test.dart`, T217) tự động bắt được
  API mới thêm (12 dòng: `.en`/`.vi`/`resolve()` × 4 class) — đã review
  diff và regenerate `test/goldens/public_api_surface.txt` có chủ đích,
  đúng quy trình mà T217 tự đề ra.

**Không chạy được `codex review --uncommitted`** (hết hạn mức từ trước
trong phiên — chủ dự án đã cho phép bỏ qua).

**Tự chấm điểm: 9/10.** Trừ điểm vì (1) không chạy codex, (2) không
device-smoke riêng cho `VipRedeemStrings` (lý do đã giải thích ở trên,
không phải bỏ sót), và (3) bản dịch tiếng Việt cho ~30 field của
`VipRedeemStrings` do tôi tự dịch — nên có người bản ngữ/đội ngũ dự án
review lại trước khi ship production, dù đã cố giữ văn phong nhất quán
với 3 class kia.
