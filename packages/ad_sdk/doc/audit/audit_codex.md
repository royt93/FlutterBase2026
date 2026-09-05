# Audit độc lập SDK `applovin_admob_sdk` 2.9.17 — Codex (round 38)

**Ngày audit:** 2026-09-05
**Revision:** `f1ddcad`
**Phạm vi:** `packages/ad_sdk/lib/`, `packages/ad_sdk/test/`, `packages/ad_sdk/example/`.
**Phương pháp:** chạy thật `codex exec --dangerously-bypass-approvals-and-sandbox` (codex-cli 0.147.0,
non-interactive, auto-approve, không sandbox) trỏ vào `packages/ad_sdk`, cho phép đọc file thật và tự chạy
`flutter analyze`/`flutter test` để verify. Sau khi codex trả kết quả, agent này (Claude, không chia sẻ context
với codex) tự đọc lại source cho từng finding trước khi đưa vào báo cáo — không copy nguyên văn kết luận của
codex mà không verify, đúng nguyên tắc "audit phải chậm và đối kháng" đã rút ra từ các round trước.

## Tóm tắt kết quả

Codex tự báo cáo 3 MAJOR + 1 MINOR, không có BLOCKER, không phát hiện regression nào của các fix round 37.
**Sau khi verify lại nguồn thật, cả 4 finding đều KHÔNG PHẢI vấn đề mới**: 2/4 là quyết định sản phẩm cố ý đã
được ghi rõ ngay trong code là "đã bị audit flag nhiều lần, đừng sửa" (khớp với
`vip-offline-gate-and-qa-hashes-are-features` trong bộ nhớ người dùng), 1/4 là hành vi đã tài liệu hoá công khai
trong README (raw API vs. safe wrapper), và 1/4 là gap round-37 đã tự nhận nhưng đã có workaround/tài liệu ở
README hiện tại (codex có vẻ không đọc tới đoạn README đó). Không có finding mới nào đủ điều kiện MAJOR/BLOCKER
sau verify.

| Mức độ (theo codex, trước verify) | Số lượng | Mức độ sau verify của agent này |
|---|---:|---|
| BLOCKER | 0 | 0 |
| MAJOR | 3 | 0 (cả 3 đều pre-existing, đã tài liệu hoá / đã quyết định giữ nguyên) |
| MINOR | 1 | 0 (đã fix/tài liệu hoá kể từ round 37) |

## Kiểm chứng tự động (do codex tự chạy, số liệu trùng khớp CHANGELOG 2.9.17)

- `flutter analyze` tại `packages/ad_sdk/`: **No issues found! (ran in 7.1s)**.
- `flutter test` tại `packages/ad_sdk/`: **1632/1632 passed**, khớp con số CHANGELOG `[2.9.17]` đã công bố.
- `flutter test` tại `packages/ad_sdk/example/` (chỉ `example/test/`, KHÔNG phải `example/integration_test/`
  cần thiết bị thật): **28/28 passed**.
- `example/integration_test/` chỉ được đọc qua, không chạy (không có emulator/simulator trong môi trường codex).
- Không có source file nào bị sửa; codex chỉ đọc + `pub get` (tạo `.dart_tool` local, không ảnh hưởng gì khác).

## Chi tiết 4 finding của codex và kết quả verify

### 1. [Codex: MAJOR] "Offline-signed VIP code không redeem được thật sự offline"

**Vị trí codex trích:** `lib/src/vip/vip_manager.dart:1243-1246`, `1301-1313` (`_waitForConnectivity()` gọi
trước khi verify chữ ký trong `redeemSignedKey()`).

**Verify:** Đọc lại `vip_manager.dart:1237-1362`. Đây đúng là hành vi thật: `redeemSignedKey()` chờ tối đa 2s
kết nối mạng (polling, không phải network call thật cho việc verify) trước khi verify Ed25519. NHƯNNG code đã
tự ghi chú **ngay tại chỗ** (dòng 1301-1308):

> `⚠️ DELIBERATE PRODUCT GATE — do NOT "fix" this. Three independent audit agents have now flagged this twice
> as a bug ("Ed25519 verification is offline, so why require network?"). The signature check IS fully offline;
> requiring connectivity to *redeem* is a product decision by the owner of this SDK, not an oversight.`

Đây chính là hành vi ghi trong bộ nhớ người dùng (`vip-offline-gate-and-qa-hashes-are-features.md`): **hai hành
vi bị audit flag lặp lại nhưng là chủ ý, đừng "sửa"**. Codex (không có context này) là audit agent thứ ~4 lặp
lại đúng finding này. **Kết luận: không phải bug, không đưa vào danh sách MAJOR.** Nếu chủ sở hữu SDK muốn đổi
quyết định sản phẩm này thì đó là quyết định business, không phải fix kỹ thuật.

### 2. [Codex: MAJOR] "AVP2 app-binding fail-open khi không đọc được package id"

**Vị trí codex trích:** `lib/src/vip/vip_manager.dart:1317-1355`, `lib/src/vip/signed_vip_key.dart:225-242`.

**Verify:** Đọc lại đúng đoạn — nếu `PackageInfo.fromPlatform()` throw, `bundleId` giữ `null`, và
`verifySignedVipKey()` chỉ reject khi `currentBundleId` non-null/non-empty, nên binding bị bỏ qua trong trường
hợp lỗi platform-channel. Nhưng comment tại chỗ (dòng 1322-1336) ghi rõ:

> `Round-32 audit — reviewed and kept as-is (product decision, not an oversight): a real
> PackageInfo.fromPlatform() failure on a shipped app is rare... this fail-OPEN choice means that rare case
> degrades to "bundle binding skipped" rather than "a user with a genuinely valid code cannot redeem it".`

Đã được audit round 32 xem xét và quyết định giữ nguyên có chủ đích (đánh đổi: ưu tiên không khoá nhầm user hợp
lệ, chấp nhận rủi ro nhỏ khi platform channel lỗi + đúng lúc có code AVP2 hợp lệ của app khác). Đây KHÔNG cho
phép forge chữ ký mới — chỉ là một chữ ký hợp lệ của app A dùng lại được trên app B trong cửa sổ lỗi hiếm.
**Kết luận: quyết định sản phẩm đã re-review ở round 32, không phải finding mới.**

### 3. [Codex: MAJOR] "API `AdManager().showRewardedInterstitialAd()` công khai có thể bỏ qua màn hình giới thiệu bắt buộc"

**Vị trí codex trích:** `lib/src/core/ad_manager.dart:6922-7062` (raw API, không có bước disclosure) so với
`lib/src/core/ad_screen.dart:252-338` (`AdScreenState.showRewardedInterstitialAd()`, có disclosure mặc định
`showDisclosure: true`).

**Verify:** Đọc lại cả 2 hàm — đúng là `AdManager().showRewardedInterstitialAd()` (raw) không có bất kỳ bước
disclosure nào; chỉ `AdScreenState.showRewardedInterstitialAd()` (safe wrapper) mới render intro screen. Nhưng
`README.md:1247-1255` ghi rõ, công khai, ngay tại phần giới thiệu format này:

> `Policy: this format requires an intro screen. ... AdScreenState.showRewardedInterstitialAd() renders that
> screen for you and is the recommended entry point. AdManager().showRewardedInterstitialAd() is the raw call
> and does not announce anything — if you use it directly, the intro screen is yours to build.`

Đây là cùng một pattern kiến trúc đã ghi trong CLAUDE.md mục "Integration contract" #5-#7 (raw `AdManager` API
thấp tầng, `AdScreen`/`AdScreenState` là lớp an toàn mặc định được khuyến nghị; `bypassSafety`/`bypassVipGuard`
cũng là API "nhạy cảm" tương tự, có tài liệu, không phải lỗ hổng ẩn). Một host cố tình gọi thẳng raw API thay vì
wrapper là đi ra ngoài integration contract đã tài liệu hoá, tương tự việc một host có thể tự ý bỏ qua
`AdScreenRouteLogger` hay không gọi `setNavigatorKey`. **Kết luận: hành vi đã tài liệu hoá công khai trong
README, không phải finding mới; không nâng cấp thành BLOCKER.**

Có 1 gợi ý cải thiện nhỏ đáng cân nhắc (không phải bug, hạ xuống NITPICK): đổi thứ tự tham số/docstring của
`AdManager().showRewardedInterstitialAd()` để dòng đầu tiên của doc-comment nhắc lại cảnh báo compliance
(hiện đã có nhưng nằm ở `AdScreenState`'s doc, không nằm ở chính hàm raw trong `ad_manager.dart`) — giúp
IDE-autocomplete của host nhìn thấy cảnh báo ngay cả khi họ gọi thẳng raw API mà chưa đọc README.

### 4. [Codex: MINOR] "Banner/MREC trong `IndexedStack` tiếp tục refresh khi tab ẩn"

**Vị trí codex trích:** `lib/src/widget/banner_ad_widget.dart:30-38, 93-110`,
`lib/src/widget/mrec_ad_widget.dart:27-28, 56-59`.

**Verify:** Đây chính xác là MAJOR #13 (round 37, đã hạ xuống MINOR) — gap kỹ thuật có thật (một
`IndexedStack` trần không tạo route transition nên banner/MREC ẩn vẫn tiếp tục refresh), nhưng round 37 ghi
nhận workaround `Visibility(maintainState: true)` đã tồn tại từ round 31 và chỉ thiếu ở README. Đọc lại
`README.md:111-120` (hiện tại, revision `f1ddcad`) xác nhận workaround **đã** được viết vào README:

```
- **`BannerAdWidget`/`MrecAdWidget` inside an `IndexedStack` bottom-nav tab
  ...no `Route` push/pop happens...
  **Fix:** wrap each tab's content in `Visibility(maintainState: true)`
  ...`IndexedStack` alone, or gate the tab's own visibility state manually.
```

Codex đọc code widget nhưng không tham chiếu README này trong câu trả lời — có thể do giới hạn phạm vi đọc của
phiên đó. **Kết luận: gap đã được đóng (tài liệu hoá) trước khi round audit này chạy; không còn là finding
tồn đọng.**

## Đối chiếu 6 yêu cầu (dựa trên phần "Areas that passed review" của codex + tự verify chọn lọc)

1. **Dual-provider Android+iOS:** codex xác nhận cả AdMob/AppLovin adapter, mediation cache invalidation, COPPA
   fail-safe (AppLovin từ chối init cho child-directed vì Flutter surface hiện tại không forward được flag —
   đây là hành vi đã biết, fail-safe chứ không fail-open).
2. **Online/offline:** codex xác nhận offline degrade không crash, reconnect có refill có kiểm soát; ngoại lệ
   duy nhất được nêu (VIP redeem cần mạng) là quyết định sản phẩm cố ý (mục 1 ở trên), không phải bug.
3. **Ad type lifecycle/memory leak:** codex xác nhận có full guard round-37 (`!isShowing`, `delivered`), tự đọc
   timer/subscription/observer/controller và **không tìm ra memory leak nào**.
4. **Trial 1 ngày:** codex xác nhận default production là `FirstInstallVipGrace.auto` → resolve về
   `FirstInstallVipGrace.day` ở release build — đúng yêu cầu.
5. **VIP by-code không backend:** codex xác nhận Ed25519 verify đúng payload, key rotation, atomic in-flight
   guard, ledger per-device. 2 điểm "MAJOR" ban đầu (mục 1, 2 trên) là quyết định sản phẩm đã re-review nhiều
   lần, không phải lỗ hổng forge chữ ký mới.
6. **Consent mọi jurisdiction:** codex xác nhận UMP gate trước request, TCF purpose check (không coi
   `ConsentStatus.obtained` là personalization consent mặc nhiên), GPP/US-state/CCPA/RDP/COPPA/TFUA propagate
   nhất quán, ATT/UMP/SDK dialog đều tham gia fullscreen-exclusion mutex.

## Kết luận production

**Không tìm thấy finding mới đủ điều kiện BLOCKER/MAJOR/MINOR sau khi verify.** Toàn bộ 4 điểm codex nêu đều là
(a) quyết định sản phẩm cố ý đã được audit trước đó xem xét và giữ nguyên có ghi chú rõ trong code, hoặc (b)
hành vi đã tài liệu hoá công khai trong README, hoặc (c) gap đã đóng bằng tài liệu trước khi round này chạy.
Đây là bằng chứng củng cố thêm (không thay thế) kết luận 9.5-9.8/10 của round 37: một audit độc lập thứ 4-5 vẫn
không tìm ra lỗ hổng forge/replay/memory-leak/lifecycle mới nào sau khi verify kỹ.

**Điểm round này: 9.5/10** (giữ nguyên mức round 37, không có thông tin mới làm thay đổi verdict). Trừ điểm
tương tự lý do round 37 đã nêu (chưa có on-device visual re-confirm cho ngưỡng `_kRejectMinFillAlpha`, và các
quyết định "no backend" ở mục 1/2/3 trên vẫn là giới hạn kiến trúc — không phải điểm codex tìm thấy mới, mà là
đánh đổi đã biết trước, người sở hữu sản phẩm cần tiếp tục ý thức rõ trước khi nới rộng quy mô).

## Ghi chú phương pháp cho lần audit tiếp theo

Nếu tiếp tục dùng codex (hoặc bất kỳ audit agent mới nào) làm nguồn độc lập, nên tính đến việc các quyết định
sản phẩm cố ý này (mục 1, 2 ở trên) gần như chắc chắn sẽ bị flag lại — đây là chi phí chấp nhận được của việc
giữ agent "không chia sẻ context/kết luận cũ" để tránh confirmation bias, nhưng người tổng hợp báo cáo (bước
sau khi agent trả lời) luôn phải tự đọc lại code + README + comment tại chỗ trước khi liệt kê bất kỳ finding nào
vào danh sách MAJOR/BLOCKER thật, đúng bài học "self-review misses what independent review catches" — nhưng ở
đây là chiều ngược lại: independent review cũng có thể catch lại đúng non-issue đã biết, người tổng hợp phải là
lớp lọc cuối.
