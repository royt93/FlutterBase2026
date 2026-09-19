# Audit vòng 6 — hợp nhất 4 auditor độc lập (2026-08-23)

Bản audit này chấm **toàn bộ SDK theo 7 yêu cầu sản phẩm**, không phải chấm một diff. Đó là lý do điểm thấp hơn hai vòng ngay trước (8.5 và 8.0) — hai vòng đó chỉ soi 26 commit thay đổi.

## Cách chạy

| Auditor | Phạm vi | Nơi làm |
|---|---|---|
| codex CLI | cả 7 tính năng, ý kiến độc lập | repo chính |
| Auditor A | consent mọi quốc gia + policy | git worktree riêng |
| Auditor B | vòng đời 4 loại ad + memory leak | git worktree riêng |
| Auditor C | VIP offline + trial + bảo mật | git worktree riêng |

Mỗi auditor một **worktree riêng** nên chạy song song thật mà không đè lên nhau khi revert-thử. Đây là điểm sửa từ tai nạn `606cfe7` (2 agent chung tree, commit nhầm bản revert, xoá mất 4/6 chỗ fix MJ15).

**Lần chạy đầu thất bại:** 3 auditor chết lúc 01:26 vì máy Mac ngủ giữa lúc làm ("computer went to sleep mid-response" + 2 cái treo watchdog 600s). Mất toàn bộ công việc của chúng. Chạy lại dưới `caffeinate` kèm hạn 25 phút phải báo cáo — "dở mà về được" hơn "kỹ mà mất trắng".

---

# BLOCKER (1)

## B1 — Thu hồi consent chỉ bắt 1 trong 3 trục
`lib/src/core/ad_manager.dart:2632-2634`

```dart
final downgraded = latest != null &&
    _lastAppliedConsent?.hasUserConsent == true &&
    !latest.hasUserConsent;
```

`downgraded` là **trigger duy nhất** cho `discardCachedFullscreenAds()` + `personalisationRevision++`. Nó không bật khi `doNotSell` (CCPA) chuyển false→true, cũng không bật khi `isAgeRestrictedUser` (COPPA) chuyển false→true.

**Hậu quả:** người dùng bấm "Do Not Sell My Info" giữa phiên ⇒ ad đã nạp **không** kèm `rdp=1` vẫn chạy, banner/MREC/native đã mount vẫn tự làm mới bản nạp trước opt-out. Với COPPA nghiêm trọng hơn: bật cờ trẻ em giữa phiên ⇒ ad không child-directed tiếp tục phục vụ người dùng vừa được khai dưới 13 tuổi. COPPA là trục **khắt khe hơn** nhưng lại được bảo vệ **ít hơn** trục personalisation.

**Verified RED** bằng probe test: `Expected: a value greater than <0> / Actual: <0>`. Không test nào trong 952 phủ 2 chuyển đổi này (`consent_withdrawal_discard_test.dart` chỉ phủ 3 tổ hợp của `hasUserConsent`).

**Ghi nhận trung thực:** điều kiện này do chính tôi viết ở vòng 5 (mục B1/MJ5) và chỉ phủ 1 trục. Cùng dạng lỗi vừa bị bắt ở m18 hôm trước: **áp fix cho phần lớn thành viên của một họ rồi tuyên bố xong.** Lần này hệ quả là pháp lý, không phải doanh thu.

**Minimum fix:** đổi guard thành "bất kỳ trục nào thắt lại":
```dart
final prev = _lastAppliedConsent;
final downgraded = latest != null && prev != null &&
    ((prev.hasUserConsent && !latest.hasUserConsent) ||
     (!prev.doNotSell && latest.doNotSell) ||
     (!prev.isAgeRestrictedUser && latest.isAgeRestrictedUser));
```

---

# MAJOR (6)

## M1 — App Open nổ khi người dùng quay về từ cú click quảng cáo
**Hai auditor độc lập trùng nhau** (codex M2 + Auditor A M1) · `ad_manager.dart:3386` + `ad_safety_config.dart`

Click *có* được ghi (`recordAdClick`, 14 call site ở cả 3 widget inline và cả 2 adapter) nhưng chỉ chảy vào `_clickTimestamps` (cửa sổ chống spam 60s) và `_totalClicks` (CTR). **Đường resume không đọc bất kỳ cái nào.**

User bấm banner/native → mở browser hoặc Play Store → app background → quay lại sau `minTimeAppOpenResume` → bị đập App Open. Đúng ca Google nêu tên trong policy App Open. Guard tương đương cho fullscreen dismiss **đã có sẵn** ở dòng 3432 — click inline chỉ là chưa được nối vào. `bypassSafety` không liên quan; đây là đường resume mặc định.

**Fix:** ghi `_lastAdClickAt` cạnh `recordAdClick()`, thêm 1 guard cạnh dòng 3432 dùng cùng cửa sổ 5s (hoặc lớn hơn).

## M2 — `resetSession()` là API public, xoá cả lịch sử invalid-traffic đã lưu
**Hai auditor trùng nhau** (codex M5 + Auditor A M2) · `ad_safety_config.dart:667-692`, export ở `lib/applovin_admob_sdk.dart:29-30`

Xoá `_suspiciousViolationCount`, `_scoreableViolationCount`, `_lastViolationTimestamp`, `_suspiciousPauseUntil`, `_clickTimestamps`, `_totalClicks/_totalImpressions` — **và ghi đè cả bản lưu** (`setSuspiciousCount(0)`, dòng 689). Thiết kế cooldown lũy tiến 30 phút → 24 giờ bị phá bằng một lệnh gọi. Còn tới được từ `AdManager().destroy()` (dòng 3068) cũng public. Example ship sẵn nút gọi trực tiếp.

**Fix:** đánh `@visibleForTesting` + bỏ khỏi danh sách export, hoặc tách state đã persist ra để `resetSession()` chỉ xoá bộ đếm trong phiên.

## M3 — AppLovin banner/MREC no-fill bị nuốt hoàn toàn
`applovin_adapter.dart:1447-1476` (`onAdLoadFailedCallback`)

Handler lặp `_bannerSlotsByKey.keys` / `_mrecSlotsByKey.keys` và chỉ hành động `if (slot.isLoading)`. **Cả hai điều kiện đều chết trong production:**

1. Không có gì đưa slot banner/mrec của AppLovin vào `loading` — `beginLoad()`/`beginReload()` trong file này chỉ xuất hiện cho appOpen/interstitial/rewarded (đã đếm: 13 chỗ, không chỗ nào là banner/mrec). Khác AdMob, nơi cả banner/mrec/native đều gọi `beginLoad()` trước khi tạo ad.
2. `preloadBanner`/`preloadMrec` thành công chỉ ghi `_bannerAdViewIdByKey` — `_bannerSlotsByKey` **vẫn rỗng**, nên thân vòng lặp không bao giờ chạy.

**Hậu quả:** trên AppLovin, banner/MREC không có fill ⇒ widget đứng ở shimmer 50px suốt phiên. Listener của chính widget chỉ log (`banner_ad_widget.dart:531`), còn nhánh "banner had error, recreating" của `onAppResumed` bám vào `hasError` nên không bao giờ retry. **Cũng không phát `AdLoadEvent(success:false)`**, nên giám sát fill-rate/anomaly mù hoàn toàn với mọi lỗi banner AppLovin.

**Vì sao 5 vòng không thấy:** test tự tay set `hasError` (`applovin_adapter_test.dart:781,803`).

**Fix:** gọi `_bannerSlotFor(key).beginLoad()` (tương ứng `_mrecSlotFor`) ngay trước `_bridge.preloadWidgetAdView`. Việc đó vừa đăng ký key vào slot map vừa làm filter `isLoading` hoạt động như thiết kế. `markReady()` không phụ thuộc state nên không ảnh hưởng gì khác. Kèm lợi ích: 2 format này có luôn `armLoadWatchdog` mà bản AdMob đã có còn AppLovin thì không.

## M4 — 6 chỗ callback GMA tới muộn ghi vào `ValueNotifier` đã dispose
`admob_adapter.dart:1604-1644` (banner), `1749-1783` (mrec), `1866-1895` (native)

Closure listener capture `listenables` và `slot` làm biến local. Guard `identical(_bannerSlotsByKey[key], slot)` của MJ21/B-2 chỉ phủ cửa sổ `await` **trước khi tạo ad**; sau `..load()` còn một cửa sổ dài hơn nhiều (tới khi native fill về) mà cuộn nhanh hoặc pop route sẽ chạy `disposeXInstance(key)` và dispose đúng các notifier đó.

**Verified** bằng probe: `A ValueNotifier<bool> was used after being disposed. admob_adapter.dart 1751:34`.

Debug/profile: ném ra khỏi method-channel handler của plugin (spam exception / màn đỏ). Release: lành (assert bị compile bỏ). Nên đây là crash phía developer, không phải crash trên store — nhưng là **6 call site** (`onAdLoaded` + `onAdFailedToLoad` × 3 format) nơi fix chỉ được áp cho nửa trước.

**Fix:** dòng đầu mỗi callback, dùng đúng guard identity đã có ở dòng 1586.

## M5 — CRL không bao giờ chạm entry đang active
**Ba nguồn độc lập trùng nhau** (codex M4 + Auditor C M1 + tôi tự kiểm) · `vip_manager.dart:761`

Đây là chỗ **duy nhất** tra `_revokedKeyIds`. `refreshRevocationList` (`:869-871`) chỉ thay set và cache CRL, không làm gì khác. Auditor C chứng minh bằng test: redeem AVP2 `kid=leaked` (30 ngày) ⇒ `isActive=true`; áp CRL mới thu hồi `leaked` ⇒ log `applied 1 revoked kid(s)`, rồi vẫn `isActive=true entries=[SIGNED_LEAKED]`.

Key bị lộ đã redeem trên N máy giữ nguyên cả window trên N máy đó; CRL chỉ chặn máy thứ N+1. Attacker không cần năng lực gì ngoài việc có key bị chia sẻ.

**Fix khả thi — entry CÓ ghi kid:** `redeemSignedKey:789` đặt `key: 'SIGNED_${parsed.keyId}'`. Ba lưu ý bắt buộc:
1. `normaliseKey` uppercase nên `kid` `abc` và `ABC` chung một entry key ⇒ mint kid một kiểu chữ, hoặc thêm field kid nguyên bản vào `VipEntry`.
2. Với `stack: true`, entry sau đã hấp thụ window của key bị thu hồi vào `expiresAt` của nó ⇒ purge không lấy lại được phần thời gian đó.
3. **CRL phát hành sai là không hoàn nguyên được từ phía khách.** Đề xuất của Auditor C, tôi thấy hợp lý: **đừng xoá — clamp `expiresAt` của entry bị thu hồi về `now + 24h`.** Phát hành sai thì khách trả tiền chỉ mất 1 ngày và support có cửa sổ cấp lại; key bị lộ thì ngừng sinh lợi trong vòng 1 ngày.

Phụ: đường cache CRL fail **open** khi verify lỗi (`:818`) — đúng cho tính khả dụng, nhưng nghĩa là xoá/làm hỏng pref plaintext `ad_sdk_vip_revocation_cache_v1` sẽ vô hiệu hoá revocation tới lần fetch thành công kế tiếp (cần root/emulator).

## M6 — Store VIP fallback plaintext nhận entry bịa
`_vip_entries_store.dart:51-52`

Đọc `AdPreferences.getVipEntriesFallbackRaw()` (SharedPreferences plaintext, đường T71 cho Keystore lỗi) **trước** short-circuit migration, tức trên mọi máy có secure store rỗng. Integrity là FNV-1a **không khoá**, salt hardcode và đã publish (`ad_preferences.dart:195`) — tái tạo được từ source trên pub.dev (chính `test/vip_entries_store_test.dart` đã re-implement nó).

**Verified:** với secure storage khoẻ-nhưng-rỗng và một `flutter.ad_sdk_vip_entries_fallback_v1 = "<fnv>|[{key:FORGED, expiresAt:2099-…}]"` được cắm vào, `store.getRaw()` trả về JSON bịa ⇒ VIP vĩnh viễn.

Năng lực cần: ghi được `FlutterSharedPreferences.xml` — root, emulator, hoặc đường backup/restore. **Không** làm được chỉ bằng app Settings. Không ghi đè được giá trị secure đang sống, chỉ điền vào chỗ rỗng.

**Phần bất khả kháng:** không khoá integrity offline nào sống nổi qua decompiler + root. **Fix vẫn giúp:** giới hạn những gì fallback được phép nói — chỉ nhận entry từ fallback tới một trần ngắn (ví dụ `now + 24h`), để trường hợp xấu nhất là 1 ngày chứ không phải vĩnh viễn.

---

# MINOR (nhóm, đã verify hoặc có bằng chứng rõ)

- **Watchdog native thiếu cập nhật `hasError`/`isLoaded`** mà 2 sibling đều làm (`admob_adapter.dart:1849-1852` vs `1559-1566`, `1729-1734`). Họ 3 thành viên, 2 được fix. Hậu quả: shimmer native giữ nguyên chiều cao template mãi, và vòng retry lúc resume (bám `hasError`) không bao giờ chạy — trong khi banner và MREC đều hồi phục. **Đây lại đúng dạng lỗi "họ áp thiếu".**
- **`_disposedNativeKeys` phình vô hạn**, pin `State` đã dispose (`applovin_adapter.dart:321,361,374`). Chính là kiểu phình mà comment nói tombstone được viết ra để chặn, chỉ dịch chỗ. `Expando` là store weak-key tự nhiên nhưng ném lỗi với key `String` mà test đang dùng.
- **Ledger chống replay trên Android không có bảo vệ** (`_redeemed_key_ledger.dart:51,67` early-return khi không phải iOS). One-time-use trên Android dựa hoàn toàn vào list plaintext không checksum, trong khi entitlement thì được Keystore mã hoá. Xoá đúng một pref key (root/emulator) là redeem lại được; với `stack: true` mỗi lần thêm một window tới trần 90 ngày. **Fix:** bỏ cổng `if (!_platformIsIos())` — `VipEntriesStore` đã chứng minh `flutter_secure_storage` chạy trên Android.
- **`usPrivacyOptedOut` / `gppConsentString` đọc nhưng không truyền đi** (`ad_manager.dart:748-760`). Comment lập luận "cả 2 native SDK tự đọc signal thật", chấp nhận được — nên đây là *looks risky*, không phải provably wrong. Nhưng host nào đọc `AdManager().consent` sẽ thấy `doNotSell=false` dù CMP đã ghi `IABUSPrivacy_String=1YYN`.
- **Nhánh COPPA early-return bỏ qua `_adapter?.applyConsent`** (`ad_manager.dart:2539-2572` vs `:2595`). Lành hôm nay vì nhánh đó re-init, nhưng một thay đổi `doNotSell` gói cùng lệnh `setConsent` sẽ không tới `_restrictedDataProcessing` của adapter đang đi ra.
- **`bypassSafety=true` bỏ cả lớp chống invalid traffic**, không chỉ frequency cap (codex M3) — mà splash dùng đúng cờ này. *Lưu ý: Auditor A kiểm và kết luận ngược — `bypassSafety` chỉ skip block throttle ở dòng 3345, không skip VIP/adapter-null/`canRequestAds`. Hai auditor bất đồng ⇒ cần xác minh lại trước khi sửa.*
- **Crash guard mặc định nuốt lỗi của host** nếu stack đi qua SDK, và tự bọc lặp sau mỗi re-init (codex M1).
- **CRL fetch không timeout** (codex m2). **Trần 90 ngày đo bằng đồng hồ attacker** (thuộc họ MJ9, không mở lại). **Package release vẫn mang dep UI `confetti`** (codex m5). **Trial Android bypass được bằng clear-data** — ma trận bypass trong doc liệt kê uninstall+reinstall mà thiếu clear-data, cùng bypass nhưng ma sát thấp hơn.

---

# ĐÁNH GIÁ 7 TÍNH NĂNG

| # | Yêu cầu | Kết luận |
|---|---|---|
| 1 | Provider AdMob/AppLovin, cả Android + iOS | **ĐẠT có điều kiện** — parity lệch: banner/mrec AppLovin không có slot state + watchdog như AdMob (M3) |
| 2 | Có mạng / không mạng | **ĐẠT** — cả 4 auditor không ai tìm được lỗi ở trục này |
| 3 | 4 loại ad: pháp lý, vòng đời, không leak | **KHÔNG ĐẠT** — M3, M4, watchdog native. Riêng 4 format **fullscreen** thì tốt: đếm đủ cả 4 đều dispose ad và bắn callback ở cả 3 nhánh |
| 4 | Trial 1 ngày | **ĐẠT trên iOS, KHÔNG ĐẠT trên Android** — clear-data từ app Settings là cấp lại vô hạn. Bất khả kháng khi không backend, không phải lỗi code |
| 5 | VIP bằng code, không backend, bảo mật | **ĐẠT phần crypto, có điều kiện phần còn lại** — không tìm được đường giả mạo key; không có private key nào bị commit. Rủi ro nằm ở xử lý state *sau* verify: M5, M6 |
| 6 | Consent mọi quốc gia, cả 2 provider | **ĐẠT phần áp dụng, KHÔNG ĐẠT phần thu hồi** — B1. Thứ tự áp trước mọi ad request đúng ở cả 2 provider, pre-init đúng, COPPA fail-closed trên AppLovin đúng |
| 7 | Policy AdMob/AppLovin | **KHÔNG ĐẠT** — M1 (App Open sau click) và M2 (xoá được lịch sử fraud) |

---

# CÓ NÊN DÙNG CHO PRODUCTION APP?

**Chưa — nhưng không phải vì kiến trúc sai.**

Ba lý do chặn, theo mức nghiêm trọng:

1. **B1 là vấn đề pháp lý**, không phải doanh thu. Một người dùng bật cờ COPPA hoặc opt-out CCPA giữa phiên vẫn tiếp tục nhận ad đã nạp theo consent cũ. Đây là loại việc bị soi khi có khiếu nại, và nó rơi đúng vào tính năng bạn nêu là "consent cho mọi quốc gia, apply chuẩn".
2. **M1 + M2 là rủi ro tài khoản AdMob**, không phải rủi ro người dùng. App Open đập vào mặt người vừa click ad là ca policy Google nêu tên; còn lịch sử invalid-traffic xoá được bằng một lệnh gọi public thì lớp chống gian lận chỉ còn là hình thức.
3. **M3 là lỗi người dùng thấy được** trên provider AppLovin: không có fill thì màn hình đứng shimmer giả suốt phiên, và bạn **không có số liệu** để biết điều đó đang xảy ra vì event thất bại không được phát.

**Điều đáng nói theo hướng tích cực:** phần khó nhất lại đúng. Crypto Ed25519 không có đường giả mạo. Không private key nào bị commit. Thứ tự áp consent trước mọi ad request đúng ở cả 2 provider. 4 format fullscreen sạch — đếm đủ từng thành viên. Trục "có mạng/không mạng" không ai tìm được lỗi.

Không finding nào cần đổi kiến trúc. Ước lượng: **B1 ~10 dòng · M1 ~5 dòng · M2 ~1 dòng export + tách state · M3 ~2 dòng · M4 ~6 dòng · M5 ~10 dòng + 1 quyết định sản phẩm · M6 ~5 dòng.** Phần lớn là copy pattern đã có sang chỗ thiếu.

---

# BÀI HỌC LẶP LẠI LẦN THỨ SÁU

Ba trong số các finding nặng nhất vòng này — **B1, M4, và watchdog native** — đều cùng một dạng: **fix được áp cho phần lớn thành viên của một họ rồi tuyên bố hoàn thành.** B1 phủ 1/3 trục consent. M4 phủ nửa trước của cửa sổ await, 6 call site còn lại không. Watchdog native là thành viên thứ 3 bị bỏ trong họ 3 người.

Hôm trước, m18 cũng đúng dạng này (2/3 hàm `canShow*`). Tôi đã rà "họ" sau đó và tự kết luận là đủ — nhưng tôi rà bằng grep theo mẫu tôi tự đoán, nên chỗ nào đoán sai mẫu thì tôi không thấy. Chính lượt rà đó báo động giả 3 lần vì `Future<void>` khác `void`, vì cửa sổ `-A4` quá hẹp, vì log ghi `THREW` khác `show THREW`.

**Kết luận về phương pháp: đếm họ bằng grep không thay được đọc từng đường.** Cả ba finding trên đều do auditor đọc code và viết probe test chạy thật, không phải do đếm mẫu.
