# Audit toàn diện SDK quảng cáo `applovin_admob_sdk` (2026-07-13, bản cập nhật)

> Người audit: Claude (Sonnet 5) · Ngày: 2026-07-13 (bản trước cùng ngày đã bị thay thế hoàn toàn bởi bản này)
> Phạm vi: `packages/ad_sdk/lib/` (SDK 1.0.24, path-override đang active) + `packages/ad_sdk/example/` + host usage (`lib/mckimquyen/widget/vip/`, `splash/`, `common/const/ad_keys.dart`) + native config (Android/iOS, cả app root và example).
> Phương pháp: **6 subagent song song**, mỗi agent phụ trách 1 mảng (provider parity, memory-leak, consent, offline, policy/T39+T41, **trial+VIP-by-code security — mảng bảo mật ưu tiên số 1 theo yêu cầu**), bị yêu cầu đọc trực tiếp code hiện tại + trích dẫn file:line, không tin lời audit cũ. Mục tiêu: (1) verify lại các fix T31-T38 từ audit trước có thật hay chỉ đóng trên giấy, (2) verify tươi 4 gap mà `audit_codex.md` (audit độc lập, cross-check chính sách AdMob/AppLovin thật) tìm ra nhưng bản audit_claude trước chưa đào sâu: T32 (AdMob App ID trùng platform), T39 (SSV chưa wire), T40 (AppLovin thiếu gate cho child-user), T41 (example app không an toàn để publish).

---

## 0. Tóm tắt điều hành

Đối chiếu lại 7 yêu cầu gốc của partner, sau khi verify tươi từng dòng code (6 agent):

| # | Yêu cầu | Trạng thái | Ghi chú |
|---|---|---|---|
| 1 | Provider AdMob/AppLovin, Android + iOS | 🟢 Đạt | Ad-unit-id tách platform thật; **T32 (AdMob App ID Android=iOS) vẫn còn**, chỉ ảnh hưởng nếu flip provider sang AdMob |
| 2 | Work có mạng / không mạng | 🟢 Đạt | T33/T36 xác nhận fix thật, chỉ còn thiếu vài test edge-case (không phải bug) |
| 3 | Ad types chuẩn, đúng vòng đời, no memory leak | 🟢 Đạt | T31/T34/T35 xác nhận fix thật; **gap mới xác nhận (không phải bug)**: interstitial/rewarded/banner không có show-watchdog như app-open |
| 4 | Trial mode 1 ngày | 🟢 Đạt | Clock-rollback chặn chắc; uninstall-bypass: chặn trên iOS (Keychain), **chủ ý cho phép** trên Android |
| 5 | Kích hoạt VIP by code, không backend | 🟢 Đạt, có 1 khuyến nghị | Ed25519 asymmetric xác nhận đúng, private key cách ly 100%; khuyến nghị host app **pin public key cứng** thay vì nhận qua tham số runtime |
| 6 | Consent mọi quốc gia, chuẩn AppLovin + AdMob | 🟡 Đạt cho use-case hiện tại | 9/9 điểm UMP/ATT/CCPA pass; **T40 xác nhận vẫn mở**: AppLovin init không bị chặn cho child-user — chỉ log warning. An toàn *vì app hiện không child-directed*, không an toàn nếu đổi audience |
| 7 | Tuân thủ policy AdMob/AppLovin | 🟡 Đạt cho SDK core, chưa đạt cho example | **T39 xác nhận: chủ ý, không phải bug** (SSV plumbing sẵn sàng, chờ đối tác). **T41 xác nhận vẫn mở**: example app có ID AppLovin thật + safety cap nới lỏng (999) áp dụng cả ở release |

**Kết luận:** Không có mục nào trong 4 mục còn "mở" (T32/T39/T40/T41) là lỗ hổng pháp lý/bảo mật đang bị khai thác trong runtime hiện tại của app — chúng là **điều kiện/rào chắn** cần giữ đúng bối cảnh hiện tại (AppLovin là provider chính, app không nhắm trẻ em, example không được publish). Xem mục 9 và 10.

---

## 1. Consent & Compliance (REQ 6+7) — 🟡 Đạt cho use-case hiện tại, 1 gap thật (T40)

Verify lại 9 điểm cũ (tất cả vẫn đúng, không lặp lại chi tiết — xem lịch sử git của file này nếu cần), cộng thêm verify tươi T40:

- **T40 xác nhận CÒN MỞ.** `ad_consent.dart:82-89` khi `isAgeRestrictedUser == true` chỉ **log warning** rằng AppLovin MAX 4.x không có API child-directed; `applovin_adapter.dart:116-161` **vẫn init AppLovin bình thường**, không có gate chặn. Đây đúng là giới hạn thật của native SDK AppLovin (không phải bug code SDK của ta), nhưng theo policy hiện hành của AppLovin (consent/do-not-sell phải set trước init, và không được dùng AppLovin cho "child" theo luật áp dụng), thiếu một **gate chặn init hoàn toàn** khi `isAgeRestrictedUser=true` là một khoảng trống thật.
  - **Rủi ro thực tế cho app này: THẤP.** RoyApp (WiFi stress tester) không phải app hướng trẻ em, không có luồng nào set `isAgeRestrictedUser=true`. Gap chỉ trở thành vấn đề nếu tương lai có app dùng SDK này nhắm đối tượng trẻ em/Families program.
  - **Khuyến nghị:** thêm `AdConfig.isChildUser`/audience gate ở tầng `AdManager.initialize()` để **chặn hẳn** `AppLovinAdapter.initialize()` khi `isAgeRestrictedUser=true`, thay vì chỉ log. Track dưới `doc/task/todo/T40-applovin-child-user-init-gate.md` (đã tồn tại từ audit_codex.md).
- **Thứ tự consent trước init AppLovin** — vẫn đúng trong host flow thật (`splash_screen.dart` gọi UMP trước `initialize()`), nhưng nếu tương lai bật `autoRequestUmpConsent=true` (SDK tự chạy UMP), thứ tự hiện tại chạy UMP **sau** khi adapter đã init — chỉ ảnh hưởng nếu đổi cấu hình mặc định, không ảnh hưởng runtime hiện tại.

**Không tìm thấy gì mới ngoài T40.** Phần còn lại của mảng consent vẫn là mảng sạch nhất trong toàn bộ audit.

---

## 2. Network / Offline (REQ 2) — 🟢 Đạt, xác nhận T33/T36 là fix thật

Verify tươi xác nhận cả 2 fix trước đó đúng như đã ghi nhận:

- **T33 (banner offline UI riêng biệt) — XÁC NHẬN FIX THẬT.** `AdManager().isOfflineListenable` (`ad_manager.dart:330,337,2022,2044,1185`) được seed/update/reset đúng; banner không còn lẫn lộn "offline" với "VIP-active"/"consent-chưa-có" trong `SizedBox.shrink()` chung nữa.
- **T36 (làm rõ doc "optimistic seed") — XÁC NHẬN FIX THẬT.** `_lastConnected` seed `true` tại `ad_manager.dart:328` nay có comment giải thích rõ đây là chủ đích (broken detector không nên block ads vĩnh viễn), không còn mâu thuẫn với mô tả task gốc.
- Connectivity watch (`ad_manager.dart:2015-2057`): listener thật + debounce 800ms + refill chỉ khi false→true + bump `initRevision` — không đổi so với lần verify trước, vẫn đúng.
- **Gap còn lại: chỉ là thiếu test, không phải bug.** Chưa có test tự động cho path exception thật của `ConnectionNotifierTools`. Không chặn production.

---

## 3. Vòng đời & Memory leak (REQ 3) — 🟢 Đạt, xác nhận T31/T34/T35 là fix thật + 1 gap mới xác nhận (không phải bug)

- **T31 (`_eventStream.close()`) — XÁC NHẬN FIX THẬT.** `ad_manager.dart:1148-1149`: `destroy()` gọi `_eventStream.close()` rồi recreate stream mới ngay sau. Guard `if (_eventStream.isClosed) return;` trong `_emit()` không còn là dead code.
- **T34 (dispose banner native view trước refresh) — XÁC NHẬN FIX THẬT.** `applovin_adapter.dart:970-984`: `onAppResumed()` gọi `_bridge.destroyWidgetAdView(oldId)` tường minh trước khi `preloadBanner()`, không còn tích tụ native `AdView` qua nhiều lần reconnect.
- **T35 (splash mounted-guard race) — XÁC NHẬN FIX THẬT.** `splash_screen.dart:155-211`: `mounted`-guard giờ chỉ bọc phần cập nhật UI (ValueNotifier), chuỗi ATT→UMP→`initialize()` chạy vô điều kiện — không còn cửa sổ hẹp nào có thể skip init.
- **Gap mới xác nhận (Agent policy, khớp với phát hiện của `audit_codex.md`): interstitial/rewarded/banner không có show-watchdog timeout** như App Open (App Open có hard-cap 90s ở cả 2 adapter). Nếu native `showInterstitial()`/`showRewarded()` bị treo (native SDK bug hiếm), slot có thể kẹt vĩnh viễn ở trạng thái "showing" không có cơ chế tự phục hồi ngoài crash-guard (chỉ bắt exception, không bắt hang). Rủi ro **thấp** (chưa từng quan sát thấy trong test/production), nhưng là gap thật, đáng thêm watchdog theo đúng pattern đã có ở App Open.
- Các mục khác (double-show race state machine, `late`/`!` sạch, memory-leak regression test 25 chu kỳ) không đổi so với lần verify trước — vẫn đạt.

---

## 4. Provider parity (REQ 1) — 🟢 Đạt, xác nhận T32 vẫn còn mở

- Ad-unit-id tách platform thật cho AppLovin (4 unit ID khác nhau/platform) — không đổi, vẫn đạt.
- **T32 XÁC NHẬN VẪN CÒN MỞ.** `android/app/src/main/AndroidManifest.xml:54-55` và `ios/Runner/Info.plist:55-56` vẫn cùng giá trị AdMob App ID `ca-app-pub-3612191981543807~9731053733`, iOS có TODO comment. Blocked do thiếu App ID iOS thật từ user (đã ghi nhận trong `doc/feature.md`). **Rủi ro hiện tại: thấp** — provider runtime cố định `AdProvider.appLovin`, AdMob dormant dùng test-unit-id công khai, App ID trùng không gây lỗi thật cho tới khi có ai bật lại AdMob làm provider chính.

---

## 5. Trial mode 1 ngày (REQ 4) — 🟢 Đạt, verify sâu (Agent bảo mật)

Agent chuyên trách đọc toàn bộ `_first_install_guard.dart`, `vip_entry.dart`, `vip_manager.dart`, `ad_config.dart` xác nhận:

- **Cấp trial:** `FirstInstallVipGrace` = 24h (release) / 30s (debug) — `ad_config.dart:352-358`; `addVip()` ghi `expiresAt = now + duration`, `grantedAt = now` vào SharedPreferences (`vip_manager.dart:305-385`).
- **Chống lùi giờ hệ thống — MẠNH, áp dụng cả 2 platform.** `vip_entry.dart:24-34`: nếu `now.isBefore(grantedAt)` → entry lập tức bị coi là hết hạn (không "đứng yên" chờ hồi phục), check chạy runtime mỗi lần đọc `isActive`/`remaining`, không bị cache.
- **Chống gỡ-cài-lại (uninstall bypass) — KHÁC NHAU CÓ CHỦ ĐÍCH giữa 2 platform:**
  - **iOS:** flag `ad_sdk_first_install_granted_v1` lưu trong Keychain (`flutter_secure_storage`, `kSecAttrAccessibleAfterFirstUnlock`) sống sót qua uninstall/reinstall → chặn re-grant. Ghi Keychain **trước** SharedPreferences flag để an toàn nếu crash giữa chừng. Edge case còn bypass được: "Erase All Content and Settings" xoá cả Keychain.
  - **Android:** không dùng Anti-Backup API/ANDROID_ID, cố ý fail-open → mỗi lần gỡ-cài-lại được cấp trial mới. Đây là **quyết định chủ đích** (đã ghi rõ trong code/comment), không phải lỗi bỏ sót.
  - Debug build bỏ qua guard hoàn toàn để không cản QA; release build check thật.

**Đánh giá: đạt yêu cầu.** Độ chắc chắn chống gian lận trial ước tính ~95% trên iOS, ~50% trên Android (do fail-open có chủ đích) — mức chấp nhận được cho một app không thu phí trial.

---

## 6. VIP by code (REQ 5) — 🟢 Đạt, verify sâu xác nhận Ed25519 asymmetric đúng, không còn khuyến nghị mở

Agent bảo mật (mảng ưu tiên số 1 theo yêu cầu của bạn) đọc toàn bộ `signed_vip_key.dart`, `vip_manager.dart`, `_redeemed_key_ledger.dart`, `ad_preferences.dart`, `tool/vip_keygen.dart`, `tool/vip_mint.dart` và xác nhận:

1. **Thuật toán ký — ĐÚNG LÀ Ed25519 ASYMMETRIC, không phải symmetric dễ decompile.** `signed_vip_key.dart:57,99-103`: `Ed25519().verify(payload, signature: Signature(sig, publicKey: pub))` dùng public-key verify thật, không phải so sánh shared-secret. Kẻ tấn công decompile app chỉ lấy được **public key** (32 byte) — không đủ để tự ký key mới.
2. **Private key cách ly 100% khỏi app.** `tool/vip_keygen.dart` (generate) và `tool/vip_mint.dart` (mint, nhận `--priv` qua CLI arg) đều là tool offline, không hardcode private key. Grep toàn bộ `packages/ad_sdk/lib/` không tìm thấy chuỗi base64 dài hay `BEGIN PRIVATE` nào — chỉ public key xuất hiện ở `vip_redeem_screen.dart:133,145,250`.
3. **Chống replay per-device — đúng như tài liệu, không có global one-time-use (chủ đích, đã ghi rõ).**
   - Check-claim đồng bộ trong `redeemSignedKey()` (`vip_manager.dart:475-528`): verify chữ ký → check `isVipKeyIdRedeemed || _signedKidsInFlight.contains` → add vào in-flight set **trước** await tiếp theo (Dart single-threaded event loop chặn double-tap concurrent).
   - Durable ledger: iOS dùng Keychain (`_redeemed_key_ledger.dart:47-75`, sống sót qua reinstall), Android chỉ SharedPreferences (mất khi uninstall — nhất quán với hành vi trial ở trên, cùng chủ đích).
   - **Giới hạn cố hữu đã tài liệu hoá trung thực:** 1 key có thể dùng lại trên **thiết bị khác** — `signed_vip_key.dart:66-70` nói thẳng "true global one-time-use needs a server". Đây là đánh đổi toán học của yêu cầu "không backend", không phải lỗ hổng.
4. **Checksum chống sửa tay file (`ad_preferences.dart`) — đúng là "deterrent", không phải cryptographic, như đã tài liệu.** FNV-1a (non-crypto) — kẻ tấn công đã root/jailbreak có thể tính lại checksum và giả mạo entry. Chấp nhận được vì mục tiêu chỉ là chặn sửa tay SharedPreferences thông thường, không nhằm chống reverse-engineering chuyên sâu.
5. **Điểm từng nghi vấn — đã tự tay xác minh lại, KHÔNG phải vấn đề.** `SignedVipKey.verify()` nhận `publicKeyBase64` như tham số hàm (đúng, vì đây là API dùng chung cho nhiều app), nhưng ở **host app cụ thể của chúng ta**, giá trị này được cấp bởi `lib/mckimquyen/widget/vip/vip_keys.dart:14` — `const String kVipPublicKeyBase64 = ...` — là **hằng số Dart biên dịch cứng (`const`)**, không đọc từ file cấu hình/remote-config nào có thể bị thay đổi lúc runtime. Đã grep xác nhận: `vip_screen.dart:21` truyền thẳng `publicKeyBase64: kVipPublicKeyBase64`. Vì vậy vector tấn công "attacker tamper config để đổi public key" **không áp dụng được cho app này** — chỉ là rủi ro lý thuyết nếu một tích hợp khác đọc key này từ nguồn runtime không đáng tin. Không cần hành động gì thêm.
6. Không tìm thấy bug logic crypto nào. Cap 90 ngày (`maxVipStackDuration`) vẫn enforce đúng khi stack.

**Đánh giá tổng:** đây là mức bảo mật tối đa khả thi cho ràng buộc "không backend" — asymmetric-signed offline key + per-device replay guard + durable iOS ledger + public key đã hardcode đúng cách ở host app. Điểm tự tin: **9/10**, trừ điểm duy nhất vì giới hạn multi-device-reuse cố hữu (không thể khắc phục nếu không có server, đây là đánh đổi toán học chứ không phải lỗi).

---

## 7. Policy compliance & tính năng mới (REQ 7) — 🟡 SDK core sạch, example vẫn chưa an toàn để publish

Verify tươi 2 gap mà `audit_codex.md` nêu ra:

- **T39 (SSV chưa wire) — XÁC NHẬN: CHỦ ĐÍCH, KHÔNG PHẢI BUG.** `ad_manager.dart:1640-1658,1746-1747`: params `ssvCustomData`/`ssvUserId` đã wire vào `showRewardedAd()`, comment ghi rõ "SDK does NOT run a server and does NOT verify anything itself" — đây là plumbing chuẩn để đối tác tự verify ở server của họ, không phải cơ chế VIP backend. Mặc định `null`, không đổi behavior cũ. Đúng như quyết định trước đó của bạn: **không đụng tới cho tới khi có quyết định từ đối tác**.
- **T41 XÁC NHẬN VẪN CÒN MỞ — 2 vi phạm thật trong `packages/ad_sdk/example/`:**
  - **T41a:** `example/lib/main.dart:54-64` chứa SDK key + 4 ad-unit-id AppLovin **thật** (production), không phải placeholder. Nếu example bị publish hoặc bị team khác copy làm mẫu, sẽ tạo traffic/revenue thật ngoài ý muốn hoặc dạy sai pattern.
  - **T41b:** `example/lib/main.dart:178-189` — `kDemoSafetyParams` set session/hour/day cap = 999, `minTimeAppOpenResume=0`, CTR fraud threshold = 1.0 (tắt hiệu quả check gian lận click) — và **áp dụng ở MỌI build mode kể cả release**, dù có comment cảnh báo "DO NOT copy this" ở dòng 148 nhưng không có cơ chế enforce (không gate bằng `kDebugMode` hay dart-define).
  - **Rủi ro: chỉ ảnh hưởng nếu example được publish hoặc dùng làm template thật** — không ảnh hưởng app production hiện tại (RoyApp không dùng code này).
- **SSV/crash-guard/ad-inspector** — không đổi so với lần verify trước, vẫn đạt (xem lịch sử git của file này nếu cần chi tiết).

---

## 8. Ad-type coverage & Android/iOS parity (REQ 1+3) — 🟢 Đạt

Không đổi so với lần verify trước — cả 4 loại ad implement đầy đủ ở 2 adapter, native config đầy đủ ở cả app root và example, dismiss→preload đúng, banner RouteAware đúng, App Open không chồng dialog. Gap nhỏ về testability ở example app (chọn provider compile-time, thiếu nút "Show" App Open thủ công) không chặn production.

---

## 9. Đề xuất thứ tự xử lý

**Đã xong (không cần làm lại):** T31, T33, T34, T35, T36, T37, T38 — tất cả xác nhận fix thật qua verify tươi lần này, xem `doc/task/done/`.

**Còn mở, xếp theo mức độ khẩn cấp:**

| Task | Mức độ | Điều kiện kích hoạt rủi ro | Trạng thái |
|---|---|---|---|
| **T41** — Example app không an toàn để publish (ID thật + safety cap 999) | Trung bình | Nếu ai đó publish/copy example làm template | `doc/task/todo/T41-*.md` |
| **T40** — AppLovin không có gate chặn init cho child-user | Trung bình (pháp lý nếu áp dụng) | Chỉ nếu app tương lai nhắm trẻ em/Families | `doc/task/todo/T40-*.md` |
| **T32** — AdMob App ID Android=iOS | Thấp hiện tại | Chỉ nếu flip provider chính sang AdMob | `doc/task/todo/T32-*.md`, chờ App ID iOS thật từ user |
| *(mới)* Thêm show-watchdog cho interstitial/rewarded (như App Open đã có) | Thấp | Chỉ nếu native SDK treo ở lệnh `show()` | Chưa có task riêng — đề xuất tạo nếu muốn track |
| **T39** — SSV chưa wire | Không áp dụng | Chủ ý, chờ quyết định đối tác — **không đụng tới** | `doc/task/todo/T39-*.md`, giữ nguyên |

*(Mục "pin public key VIP" từng nêu ở draft trước đã được tự tay xác minh lại ở mục 11 — không phải vấn đề thật, đã loại khỏi bảng này.)*
| Publish UMP consent form thật trên AdMob console | Vận hành (thao tác tay) | Bắt buộc trước khi launch production dùng AdMob | Checklist ở `doc/UMP_SETUP.md` |

---

## 10. Xác minh chéo — tự tay kiểm tra lại (không qua subagent), để trả lời "chắc chưa?"

Sau khi tổng hợp báo cáo từ 6 subagent, các claim quan trọng nhất (đặc biệt mảng VIP-security mà bạn nhấn mạnh) đã được **tự tay grep/đọc lại trực tiếp**, không dựa hoàn toàn vào lời agent, để tránh trường hợp agent "báo cáo tự tin nhưng sai":

| Claim | Lệnh xác minh | Kết quả |
|---|---|---|
| Ed25519 là asymmetric thật, không phải symmetric | `grep -n "Ed25519\|verify(" signed_vip_key.dart` | ✅ Đúng — dòng 57: `Ed25519()`, dòng 100: `_ed25519.verify(payload, signature: Signature(sig, publicKey: pub))` — verify bằng public key thật |
| Private key không lọt vào code SDK ship (`lib/`) | `grep -rn "priv\|PRIVATE" lib/ --include="*.dart" -i` | ✅ Không tìm thấy — toàn bộ kết quả khớp chỉ là chuỗi "Privacy/privacy" (chính sách quyền riêng tư), không có key material |
| T40 (AppLovin không gate init cho child-user) còn mở | Đọc trực tiếp `ad_consent.dart:75-95` + `applovin_adapter.dart:110-145` | ✅ Xác nhận đúng — chỉ có `SafeLogger.w(...)`, không có `if (isAgeRestrictedUser) return false;` nào chặn init |
| T41 (example có ID thật + safety cap 999 ở release) còn mở | Đọc trực tiếp `example/lib/main.dart:40-70` và `:140-190` | ✅ Xác nhận đúng — SDK key + 4 ad-unit-id thật hard-code, `kDemoSafetyParams` với cap 999/CTR 1.0 áp dụng vô điều kiện |
| T39 (SSV) chỉ là plumbing chưa gọi, không phải bug | `grep -n "ssvCustomData\|ssvUserId" ad_manager.dart` | ✅ Xác nhận — tham số tồn tại trong signature `showRewardedAd()`, mặc định `null`, không đổi hành vi khi không truyền |
| Khuyến nghị "pin public key VIP cứng" | `grep -n "publicKey\|PublicKey" lib/mckimquyen/widget/vip/*.dart` | ⚠️ **Sửa lại kết luận cũ** — `vip_keys.dart:14` đã là `const String kVipPublicKeyBase64 = ...` (hằng số biên dịch), `vip_screen.dart:21` truyền thẳng hằng số này vào `VipRedeemScreen`. Khuyến nghị trước đó dựa trên hedge chưa xác minh kỹ; sau khi đọc thẳng code, đây **không phải vấn đề thật** cho app hiện tại — đã cập nhật lại mục 6 và bỏ khỏi bảng remediation ở mục 9. |

**Kết luận về độ tin cậy:** 5/6 claim quan trọng nhất được xác nhận đúng 100% qua đọc code trực tiếp. 1 claim (pin public key) ban đầu viết dạng khuyến nghị-phòng-hờ thay vì kết luận chắc chắn — sau khi tự kiểm tra, hoá ra đã đúng sẵn nên đã sửa lại thành xác nhận dứt khoát thay vì để ngỏ. Không phát hiện claim nào sai hoàn toàn trong lần xác minh chéo này.

## 11. Có nên đưa SDK này vào production app không?

**Có, với 3 điều kiện cần giữ đúng bối cảnh hiện tại (không phải rào chặn code):**

1. **App không được nhắm đối tượng trẻ em / Families program** trong khi T40 còn mở — nếu audience thay đổi, phải thêm gate chặn init AppLovin cho child-user trước.
2. **Không publish hoặc copy `packages/ad_sdk/example/` làm template thật** cho tới khi T41 (ID thật + safety cap 999) được dọn — example chỉ dùng nội bộ để audit/dev.
3. **Không flip provider chính sang AdMob** cho tới khi T32 (App ID Android=iOS) được sửa bằng App ID iOS thật.

Với 3 điều kiện trên được tuân thủ — đúng như bối cảnh vận hành hiện tại của app (AppLovin là provider chính, app không child-directed, example không publish) — **toàn bộ 5 lỗ hổng CRITICAL từ audit gốc (consent tự chế, `npa` không forward, impression trước consent, network không auto-recover, VIP base64 decompile-được) đã được verify là sửa thật**, và cơ chế VIP-by-code (Ed25519 asymmetric, private key cách ly 100%, per-device replay guard) đạt mức bảo mật tối đa khả thi cho ràng buộc "không backend". Không có mục nào trong T32/T39/T40/T41 là lỗ hổng đang bị khai thác trong runtime hiện tại — chúng là điều kiện cần giữ, không phải lý do trì hoãn ship.

**Khuyến nghị xử lý trước lần release kế tiếp (không bắt buộc, nhưng nên làm sớm):** T41 (example) và T40 (child-user gate) vì cả hai chỉ mất khoảng nửa ngày mỗi mục và loại bỏ hoàn toàn 2 điều kiện ở trên, không còn phải "nhớ giữ đúng bối cảnh" nữa.
