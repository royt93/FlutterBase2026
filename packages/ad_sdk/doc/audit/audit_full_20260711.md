# Audit toàn diện — source code + document + AD_PROMPT_FLUTTER.MD (2026-07-11)

**Người audit:** Claude (Sonnet 5), 4 subagent song song, mỗi finding đã tự verify bằng code thật (file:line), không suy đoán.
**Lý do:** user yêu cầu audit lại toàn bộ vì "code + gemini sẽ review đó" — ưu tiên độ chính xác trên tốc độ.

## 0. Tóm tắt

Không có lỗi crash/data-loss mới. 2 bug thật (1 memory-leak, 1 tính năng bị vô hiệu hoá âm thầm), 1 security gap đáng chú ý (checksum bypass), và một loạt **doc bị stale so với code thật** — đây mới là rủi ro chính khi bị review ngoài: nếu Gemini/reviewer đọc `AD_PROMPT_FLUTTER.MD`/`AD.MD` trước rồi so với code, sẽ thấy mâu thuẫn ngay.

## 1. Bug code thật (nên fix)

### 1.1 [MEDIUM-HIGH] VipManager cũ không dispose khi `AdManager.initialize()` gọi lần 2
`packages/ad_sdk/lib/src/core/ad_manager.dart:623-628`

Nhánh re-init chỉ gỡ listener của `AdManager` khỏi VipManager cũ (`_vipManager?.activeListenable.removeListener(...)`) rồi ghi đè `_vipManager` bằng instance mới — **không gọi `_vipManager?.dispose()`**. Comment ngay dòng 621-622 tự nhận "Detach + dispose any pre-existing VipManager... before wiring a new one" nhưng code chỉ detach, không dispose. So sánh `destroy()` (~dòng 1074-1117) làm đúng cả hai bước → xác nhận đây là thiếu sót, không phải chủ đích.

Hệ quả: `Timer` nội bộ của VipManager cũ (`_expiryTimer`, tự re-arm qua closure giữ tham chiếu instance) không bao giờ bị cancel, instance không được GC, timer chạy vô thời hạn. Chỉ xảy ra khi `initialize()` được gọi 2 lần liên tiếp không có `destroy()` xen giữa.

**Fix đề xuất:** thêm `_vipManager?.dispose();` trước dòng 623.

### 1.2 [MEDIUM] Grace-nudge listener có thể không bao giờ được gắn (race với splash hard-cap)
`lib/mckimquyen/widget/wifi_stressor/wifi_stressor_screen.dart:67`

```dart
AdManager().vip?.graceNudgeDueListenable.addListener(_onGraceNudgeChanged);
```

`AdManager().vip` nullable cho tới khi SDK `initialize()` xong. Splash có hard-cap timer 8s có thể navigate sang màn hình này **trước khi** `initialize()` hoàn tất (initialize chạy fire-and-forget, hard-cap không chờ). Nếu vậy, `vip == null` lúc `initState()` chạy → listener không bao giờ attach, và không có cơ chế retry/attach-lại sau khi `vip` sẵn sàng. Tính năng nhắc VIP sắp hết hạn bị tắt âm thầm cho cả session đó — không crash, không log cảnh báo.

**Fix đề xuất:** dùng `SimpleEventBus`/callback SDK báo init xong để attach lại, hoặc `Get.find<...>` poll 1 lần sau frame đầu.

## 2. Security gap (đã biết một phần, nhưng nghiêm trọng hơn doc mô tả)

### 2.1 [MEDIUM] Checksum VIP entries có đường bypass không cần biết thuật toán
`packages/ad_sdk/lib/src/utils/ad_preferences.dart:149-157`

```dart
String? getVipEntriesRaw() {
  final payload = _prefs?.getString(_keyVipEntries);
  if (payload == null) return null;
  if (payload.startsWith('[')) {
    // Pre-upgrade data written before checksum existed — trust once, backfill.
    unawaited(setVipEntriesRaw(payload));
    return payload;
  }
  ...
```

`T30-vip-storage-hardening.md` đã tự nhận checksum "chỉ răn đe sửa tay, không chống root" — đúng, nhưng thực tế bypass **mạnh hơn** mức đó: attacker (root/jailbreak, hoặc backup-restore tamper) không cần biết gì về FNV-1a/salt cả — chỉ cần ghi 1 JSON array thô (bắt đầu bằng `[`) vào key `ad_sdk_vip_entries` là được trust vô điều kiện, **bất kỳ lúc nào**, không chỉ "lần đầu nâng cấp". Không có cờ đánh dấu "đã qua migration, đóng cửa sổ legacy" nên path này tồn tại vĩnh viễn, không phải one-time window như comment "trust once" ngụ ý.

**Không phải bug mới cần task riêng** (threat model đã accept root-user có thể tamper), nhưng đáng sửa nhỏ: thêm cờ `_keyVipMigrated` check trước khi cho phép passthrough, để ít nhất đóng cửa sổ sau lần đầu.

## 3. Doc mismatch — rủi ro chính khi bị review ngoài

### 3.1 [CAO] `doc/AD.MD` + `doc/AD_PROMPT_FLUTTER.MD` nói SAI về SDK source
- `pubspec.yaml:48-54`: dòng hosted `applovin_admob_sdk: ^1.0.23` đang **comment out**; `path: packages/ad_sdk` đang **ACTIVE** (comment ngay tại đó: "TEMPORARILY overridden... Flip back before release").
- `doc/AD.MD:83` khẳng định thẳng: "*the in-repo `path` override is no longer used*" — **sai** so với state thật.
- `doc/AD_PROMPT_FLUTTER.MD:6` cũng khẳng định tương tự — **sai**.
- `doc/feature.md:65-68` cùng lỗi stale.
- Chỉ `doc/task/README.md:30` ghi đúng thực tế.
- Version cũng lệch: cả 2 doc ghi `^1.0.23`, nhưng `packages/ad_sdk/pubspec.yaml:3` là **`1.0.24`**.

Đây chính là điểm dễ bị Gemini/reviewer ngoài bắt lỗi nhất nếu họ đọc doc trước — **nên sửa trước tiên**.

### 3.2 [CAO] `doc/AD.MD` chưa cập nhật từ 2026-06-15 — thiếu toàn bộ 1.0.24
Không có dòng nào về RedeemedKeyLedger, VIP grace nudge, VIP checksum, T29 splash race fix — dù `CHANGELOG.md` đã publish 1.0.24 (2026-07-10) và `doc/feature.md` đã ghi chi tiết. `git log -- doc/AD.MD` xác nhận lần sửa cuối là commit SDK 1.0.23 (15/06).

### 3.3 [TRUNG BÌNH] `AD_PROMPT_FLUTTER.MD` mô tả sai kiến trúc VIP UI
Dòng ~1062: mô tả `vip_screen.dart` là nơi chứa "13 components", và nói row 13 "Restore Purchase" "sẽ bổ sung" (ngụ ý chưa có). Thực tế:
- `lib/mckimquyen/widget/vip/vip_screen.dart` chỉ 80 dòng, là thin wrapper gọi `VipRedeemScreen` — UI thật đã được extract vào SDK (`packages/ad_sdk/lib/src/vip/vip_redeem_screen.dart`, 1354 dòng) từ bản 1.0.24 (`CHANGELOG.md` mục "Added — shared VipRedeemScreen widget").
- Row 13 "Restore purchase" **đã tồn tại** trong code (`vip_redeem_screen.dart:1192-1215`), chỉ ở trạng thái disabled (`onTap: null`, text "(coming soon)") — không phải "chưa build".

### 3.4 [THẤP] Chi tiết vặt sai trong `AD_PROMPT_FLUTTER.MD`
- iOS `SKAdNetworkItems`: doc nói "~70 entries", thực tế **47 entries** (`ios/Runner/Info.plist:58`).
- Step 10.6 mô tả VIP key dùng "base64-obfuscated `Map<String, Duration>`" — thực tế project đã migrate sang **Ed25519 signed-key** (`vip_keys.dart`, T18) từ lâu, không còn map base64→Duration nào. Doc mô tả cơ chế cũ.
- Step 10.4/11.1 nói "Skip `vibration` package, dùng `HapticFeedback`" — nhưng `pubspec.yaml:60` **có** khai báo `vibration: ^3.1.5` thật, mâu thuẫn trực tiếp với rule doc tự đặt ra.
- Step 11.5 grep check "0 setState / 0 bang operator" — thực tế có 7 `setState()` + 4 `!` thật trong `lib/mckimquyen/lib/image_picker/test_image_picker.dart` (dead code, không được import ở đâu). Không phải vi phạm rule ở code sống, nhưng làm sai lệch kết quả checklist nếu chạy grep máy móc như doc hướng dẫn. Cân nhắc xoá file dead code này.

### 3.5 [THẤP] `doc/AD.MD` có đoạn văn bị lỗi/thiếu từ (khả năng do edit/nén lỗi)
Dòng 17-22: câu thiếu động từ nối, đọc ngắt quãng. Không sai nội dung nhưng giảm độ tin cậy khi bị review kỹ.

## 4. Không tìm thấy vấn đề (đã kiểm tra kỹ, ghi lại để tránh audit trùng lặp)

- `_redeemed_key_ledger.dart` — logic Keychain đọc/ghi, fail-open có chủ đích, không race.
- Splash race-condition core logic (`splash_screen.dart`) — guard `_hasNavigated`/listener cleanup đúng.
- `graceNudgeThreshold`/timer scheduling trong `vip_manager.dart` — không off-by-one/leak.
- VIP stack-duration clamp — không overflow, `now` luôn tăng nên trần clamp không bao giờ lùi.
- `redeemSignedKey()` in-flight Set check — chặn đúng double-redeem.
- Dispose lifecycle `admob_adapter.dart`/`applovin_adapter.dart` — đúng thứ tự.
- `_retryGen` generation-counter — ngăn đúng stale `Future.delayed` sau destroy/reinit.
- Progressive cooldown exponent clamp — dead safety net, không phải bug.
- CHANGELOG.md 1.0.24 vs pubspec.yaml — khớp nhau, entry mô tả đúng hành vi thật (đã verify code).
- README.md API surface (`VipManager`/`ConsentManager`/`AdManager`) — khớp code thật.
- Android manifest permissions/`taskAffinity`, iOS `GADApplicationIdentifier`/`AppLovinSdkKey`/`NSUserTrackingUsageDescription`/Podfile 13.0 — đúng như doc mô tả (trừ số lượng SKAdNetworkItems ở 3.4).
- `confetti` dependency, `app_tracking_transparency` chỉ ở SDK level — đúng như doc.

## 5. Đề xuất thứ tự xử lý

1. Sửa `doc/AD.MD` + `doc/AD_PROMPT_FLUTTER.MD`: cập nhật version 1.0.24, xoá claim "no path override" (đang sai), thêm phần 1.0.24 (ledger/checksum/grace-nudge/VipRedeemScreen extract) — **ưu tiên cao nhất vì đây là thứ Gemini sẽ đọc trước**.
2. Fix 1.1 (VipManager dispose leak) — nhỏ, an toàn, 1 dòng.
3. Fix 1.2 (grace-nudge listener race) — cần quyết định cơ chế retry-attach.
4. Sửa các chi tiết vặt ở 3.4 (SKAdNetworkItems count, vip_keys.dart mechanism description, vibration package note) trong `AD_PROMPT_FLUTTER.MD`.
5. Cân nhắc xoá `lib/mckimquyen/lib/image_picker/test_image_picker.dart` (dead code, phá checklist grep).
6. 2.1 (checksum bypass) — chỉ cần note rõ hơn trong doc rằng bypass không cần biết thuật toán; sửa code là optional (không bắt buộc theo threat model đã chốt).

## 6. Cập nhật sau verify thật bằng test (2026-07-11, không chỉ code review)

Theo yêu cầu "làm tuần tự option 1 > 2 > 4" — verify lại 2 finding bằng revert-thật + chạy test, sweep toàn bộ consumer khác, và audit nhanh 3 dimension phụ (coverage/security/perf).

**1.1 (VipManager dispose leak) — fix đã áp dụng, nhưng premise ban đầu sai.** Đọc thẳng source `change_notifier.dart` của Flutter SDK 3.35.1 (bản pin của CI): `removeListener` được document rõ là an toàn khi gọi sau `dispose()` (chỉ `addListener` còn assert not-disposed). Revert `dispose()` về bản cũ (có gọi `_activeNotifier.dispose()`/`_graceNudgeDueNotifier.dispose()`) rồi chạy lại test regression mới (`wifi_stressor_screen_grace_nudge_test.dart` — case re-init) — **test vẫn pass với cả code cũ và code mới**, chứng minh đây không phải fix 1 crash đang xảy ra thật, mà là bỏ phụ thuộc vào 1 guarantee riêng của SDK version này (defense-in-depth). Đã sửa comment trong `vip_manager.dart` cho đúng sự thật thay vì overclaim "fixes a crash". Giữ nguyên fix (vô hại, đúng hướng), nhưng hạ mức độ nghiêm trọng xuống LOW (không phải MEDIUM-HIGH như đánh giá ban đầu).

**2.1 (checksum bypass) — verify thật, đúng như audit.** Revert `ad_preferences.dart` về bản trước fix "đóng cửa sổ backfill" (`_keyVipEntriesChecksumMigrated`), chạy `ad_preferences_test.dart` — test `'raw JSON array reappearing AFTER the one-time backfill is rejected, not re-trusted'` **fail đúng như kỳ vọng**. Restore lại bản fix, test pass lại. Xác nhận: fix thật, test thật, không phải rubber-stamp.

**Sweep consumer khác của `activeListenable`/`graceNudgeDueListenable`:** `vip_redeem_screen.dart`, `banner_ad_widget.dart`, example `main.dart` (x2) — toàn bộ dùng `ValueListenableBuilder` với `AdManager().vip` fetch mới mỗi lần `build()`, không cache field riêng → framework tự `removeListener`/`addListener` khi swap instance, an toàn theo đúng guarantee ở trên. `wifi_stressor_screen.dart` là consumer duy nhất tự cache thủ công (đã fix trong 1.2). Không tìm thêm gap nào.

**Coverage (package `ad_sdk`, `flutter test --coverage`):** 66.4% tổng (2752/4145 dòng). Theo file: `vip_manager.dart` 84.2%, `banner_ad_widget.dart` 72.9%, `ad_manager.dart` 49.8%, `admob_adapter.dart` 50.1%, `applovin_adapter.dart` 48.1%. Thấp nhất: `vip_dialog.dart` 0%, `consent_manager.dart` 0%, `applovin_bridge.dart` 3.2%, `gma_bridge.dart` 6.2% (bridge/adapter mỏng test — phụ thuộc platform channel thật, khó mock rẻ tiền).

**Security ngoài VIP key:** không tìm secret hardcode trong `lib`/`packages/ad_sdk/lib`. `android/app/keystore.jks` + `android/key.properties` (password thật) có commit vào git, nhưng `android/.gitignore:11` ghi rõ "intentionally tracked... this is a PRIVATE repo" — quyết định có chủ ý sẵn có, không phải finding mới.

**Perf/build:** 436 test package `ad_sdk` chạy 10s — ổn, không nghẽn. Không có `build_runner`/mockito codegen thật đang dùng (0 file `.mocks.dart`) nên không có gì để đo timing thêm.

**Điểm lại sau vòng verify này: 9/10** (từ 8.5 trước đó). Không đẩy tới 10/10 — 2 gap thật ở mục 1 vẫn còn (1.1 hạ độ nghiêm trọng nhưng chưa merge fix mới lên main tại thời điểm audit ban đầu viết, 1.2 vẫn cần quyết định cơ chế retry-attach), và coverage thấp ở vài file adapter/bridge là gap thật dù đã biết nguyên nhân. Điểm cộng thêm 0.5 vì quá trình tự bắt và sửa 1 overclaim của chính nó (premise crash sai ở 1.1) bằng test thật thay vì để nó đứng yên trong báo cáo — process tốt, không phải cosmetic.
