# Audit round 32 — tổng hợp 3 agent độc lập (codex / agy-Gemini / claude), 2026-09-02

## Phương pháp

Khác các round trước (1 agent hoặc agent tuần tự), round này chạy **3 CLI agent hoàn toàn độc lập song song**, mỗi agent trên một `git worktree` riêng biệt (detached tại `b0d0368`, = 2.9.11 đã publish lên pub.dev, verify qua WebFetch), không có context của nhau, không có context của phiên orchestrator này — để tránh lỗi "tự chấm điểm cho chính mình" ([[self-review-misses-what-independent-review-catches]]):

| Agent | Lệnh | File kết quả |
|---|---|---|
| Codex | `codex exec --dangerously-bypass-approvals-and-sandbox` | `audit_codex.md` |
| agy (Gemini) | `agy -p ... --dangerously-skip-permissions --print-timeout 45m` | `audit_agy.md` (agent không tự ghi file, orchestrator phải trích từ log) |
| Claude | `claude -p ... --dangerously-skip-permissions` | `audit_claude.md` |

Mỗi agent chỉ được phép **tạo file báo cáo**, cấm sửa source (worktree cô lập khỏi working tree thật theo [[reviewer-cli-can-destroy-uncommitted-work]]) — đã kiểm tra `git status` sau mỗi lần chạy, không có edit ngoài dự kiến.

Orchestrator (phiên này) sau đó **tự đọc source thật** để verify chéo mọi BLOCKER trước khi đưa vào tài liệu này — không copy nguyên văn claim của agent con ([[audit-must-be-slow-and-adversarial]]).

## Kết quả tóm tắt theo agent

| Agent | BLOCKER | MAJOR | Verdict |
|---|---:|---:|---|
| Codex | 1 | 6 | Không nên ship nguyên trạng, phải sửa BLOCKER trước |
| agy/Gemini | 0 | 3 | APPROVED FOR PRODUCTION |
| Claude | 1 | 9 | Có thể ship, nhưng BLOCKER phải sửa trước nếu có user EEA/UK |

**3 agent ra 3 verdict khác nhau, và 2 BLOCKER được tìm ra hoàn toàn không trùng nhau** (codex tìm 1 cái, claude tìm 1 cái khác, gemini không tìm thấy cái nào). Đây chính là lý do phải chạy nhiều agent độc lập thay vì tin 1 báo cáo — 1 agent-duy-nhất sẽ để lọt ít nhất 1 trong 2 lỗi chặn production dưới đây.

## BLOCKER đã tự verify qua source thật (2 cái, độc lập, không trùng nhau)

### BLOCKER-A (do Codex tìm) — consent được ghi "đã apply" dù lệnh gửi xuống provider có thể đã thất bại

**File:** `lib/src/core/ad_consent.dart:142-219`, dữ liệu sai bị dùng tại `ad_manager.dart:4699-4703, 4782-4809, 5155-5175`.

**Đã tự đọc source xác nhận:** `applyConsentToProviders()` bọc lệnh AppLovin (`AppLovinMAX.setHasUserConsent/setDoNotSell`) và AdMob (`MobileAds.instance.updateRequestConfiguration`) mỗi bên một `try/catch` riêng, `catch (e)` chỉ log rồi nuốt exception — **không set cờ lỗi nào** — sau đó code luôn chạy tiếp tới dòng gán `_lastAppliedToProviders = c` **vô điều kiện**, bất kể 2 lệnh trên có ném exception hay không.

**Hậu quả:** các luồng reconcile-on-resume so sánh trạng thái consent thiết bị với `_committedConsent` (dựa trên `_lastAppliedToProviders`); nếu 2 giá trị này khớp nhau thì SDK coi như "đã đồng bộ", không retry. Nếu người dùng rút consent / bật "Do Not Sell" đúng lúc channel/native SDK lỗi tạm thời, SDK **tưởng đã áp dụng nhưng provider thực tế vẫn giữ config permissive cũ** — quảng cáo tiếp theo có thể vẫn personalized dù người dùng đã từ chối. Đây là vi phạm consent thật (GDPR/CCPA), không chỉ sai số liệu.

**Gemini bỏ sót vì sao:** báo cáo agy chỉ audit nhánh **đọc** TCF (`IabStorage.tcfAllowsPersonalisedAds`), không audit nhánh **ghi xuống provider** (`ad_consent.dart`) — 2 nhánh khác nhau trong cùng hệ thống consent.

### BLOCKER-B (do Claude tìm) — `IabStorage.tcfAllowsPersonalisedAds()` không bắt `TimeoutException`, phá đúng fix fail-closed của round 31

**File:** `lib/src/core/iab_storage.dart:219-227`

**Đã tự đọc source xác nhận:**
```dart
try {
  store = await _open().timeout(const Duration(seconds: 5));
} on StateError {
  return null;
}
```
`on StateError` chỉ bắt case "chưa đăng ký platform implementation" (test-harness). `TimeoutException` (Dart, ném ra khi `.timeout()` hết hạn) **không phải subtype của `StateError`** — nếu `_open()` chậm quá 5s thật (đường iOS của store này, theo chính comment trong file, "chưa từng chạy trên máy thật, CI chết từ 2026-08-09"), exception thoát thẳng ra ngoài hàm thay vì trả `false` (fail-closed) như round-31 vừa cố ý sửa.

Có 4 call site ở `ad_manager.dart` (dòng 3142, 4333, 7349, 7471); Claude đã trace từng cái — 3/4 không có try/catch bao ngoài, nên hành vi thực tế khi timeout xảy ra là unhandled exception/Future rejection, không phải fail-closed nhất quán như tài liệu round-31 khẳng định.

**Gemini bỏ sót vì sao:** báo cáo agy đọc đúng hàm này nhưng chỉ đọc phần thân chính (2 nhánh dưới, dùng `catch (e)` chung đúng là fail-closed thật) và kết luận cả hàm "tuân thủ Fail-Closed" — bỏ sót nhánh `try/on StateError` đầu tiên bao quanh chính lệnh `_open()`.

## Các finding khác đáng chú ý (chưa re-verify hết từng dòng, ghi theo agent nguồn)

Không lặp lại các mục đã biết/chấp nhận là chủ ý ([[vip-offline-gate-and-qa-hashes-are-features]]: `redeemSignedKey` yêu cầu mạng, `kQaTestDeviceHashes` always-on).

| # | Nguồn | Tóm tắt | Mức |
|---|---|---|---|
| 1 | Codex | Không có runtime fallback AdMob↔AppLovin khi 1 provider outage/no-fill — "dual-provider" là chọn 1 provider/session, không phải HA | MAJOR |
| 2 | Codex | Rewarded Interstitial trên AppLovin là no-op vĩnh viễn, không capability API/fallback | MAJOR |
| 3 | Codex | Trial 1 ngày trên Android không chống được Clear-data/reinstall (chỉ dựa Auto Backup của host) | MAJOR (giới hạn kiến trúc đã biết) |
| 4 | Codex | VIP: AVP1 legacy vẫn được chấp nhận (không expiry/bundle-binding, không one-time toàn cục), CRL fail-open khi offline dài | MAJOR |
| 5 | Codex | AVP2 bỏ qua bundle-binding nếu `PackageInfo.fromPlatform()` throw (fail-open) | MAJOR |
| 6 | Codex | "Consent mọi quốc gia" chưa auto map US-state/GPP mới vào `doNotSell`/RDP nếu CMP chỉ ghi GPP không ghi legacy USP; COPPA AppLovin đổi runtime không tự teardown | MAJOR |
| 7 | Claude (tự verify) | AppLovin Banner/MREC tính impression/revenue tại thời điểm **fill**, không phải hiển thị thật (`onAdLoadedCallback` thay vì `onAdRevenuePaidCallback` — plugin có hỗ trợ, không được wire) — mâu thuẫn trực tiếp với fix round-31 đã làm đúng cho AdMob | MAJOR |
| 8 | Claude (tự verify) | AppLovin Native **không bao giờ** phát `AdRevenueEvent` — thiếu hẳn `onAdRevenuePaidCallback` | MAJOR |
| 9 | Claude (tự verify) | `AdBootstrap.bootstrap()` không có hard-cap: splash có thể treo ~150s nếu mất mạng lúc cold-start (20s UMP + 4 vòng init timeout/backoff) | MAJOR |
| 10 | Claude (tự verify) | `example/lib/main.dart:809` thiếu guard `_navigated` (chỉ check `mounted`) — App Open có thể show sau khi đã điều hướng khỏi splash; đúng race đã fix ở `AdReadinessSplashController` round-31 nhưng không port sang code mẫu | MAJOR |
| 11 | Claude (tự verify) | `canShowRewardedInterstitialAd()` thiếu check `AdLoadingDialog.isShowing` (không đối xứng với 2 hàm chị em) → 2 dialog có thể chồng nhau (UI kẹt, không phải double-show ad thật) | MAJOR |
| 12 | Claude (tự verify) | `AdScreenRouteLogger.isDialogOnTop` chỉ thấy `Route`, mù với popup dựng qua `Overlay` trực tiếp (toast/loading-indicator bên thứ 3) | MAJOR |
| 13 | Claude (tự verify) | Fix nested-Navigator/bottom-sheet round-28 là opt-in (cần host tự làm 2 việc), không loại bỏ root cause | MAJOR |
| 14 | Claude (tự verify) | `bypassSafety` (App Open) không enforce vị trí gọi + audit trail chỉ in-memory 200 entry, mất khi restart | MAJOR |
| 15 | Claude (tự verify) | `remote_ad_safety_provider.dart`: `minSessionDurationBeforeAd` thiếu sàn `min:1` (round-30 đã vá 2 field cùng lớp, bỏ sót field này) — remote config = 0 có thể tắt gate anti-bot | MAJOR |
| 16 | agy/Gemini | (không có finding MAJOR mới nào không trùng các mục trên; 3 MAJOR của agy đều là lưu ý tích hợp, không phải bug code) | — |

## Đối chiếu checklist gốc của yêu cầu

1. **Dual-provider Android+iOS:** OK về mặt tách adapter/không leak, nhưng KHÔNG có runtime failover (#1) — nếu yêu cầu sản phẩm là "an toàn khi 1 provider sập", chưa đạt.
2. **Online/offline:** cơ chế tốt, có trần rõ; điểm yếu là UX-freeze ~150s ở bootstrap (#9), không phải crash/leak.
3. **Ad type lifecycle, đúng pháp lý, không leak:** không leak mới; có 2 lỗ hổng stacking dialog cụ thể (#11, #12) và 1 dark-pattern nhẹ ở example (#10).
4. **Trial 1 ngày:** đạt trên iOS (Keychain + high-water-mark), là "best-effort retention perk" trên Android (#3) — đúng bản chất no-backend, không phải bug.
5. **VIP by-code offline, không backend:** cơ chế Ed25519 đúng, không forge được từ decompile. Nhưng AVP1 legacy + fail-open CRL/bundle-binding (#4, #5) làm giảm bảo đảm "one-time/revocation đáng tin cậy" — chấp nhận được nếu coi VIP là entitlement local best-effort, KHÔNG chấp nhận được nếu có giá trị tài chính thật.
6. **Consent mọi quốc gia:** **2 BLOCKER nằm chính ở đây** (ghi sai trạng thái đã-apply, đọc TCF không fail-closed hoàn toàn) + US-state/GPP chưa zero-config (#6). Đây là phần rủi ro pháp lý cao nhất của toàn bộ SDK.
7. **Policy AdMob/AppLovin:** có đủ safety layer (cap/throttle/CTR-fraud), nhưng `bypassSafety` không giới hạn nơi gọi (#14) là API dễ bị lạm dụng nếu host tích hợp cẩu thả.

## Kết luận cuối cùng (orchestrator, sau khi tự verify)

**SDK 2.9.11 có nền tảng kỹ thuật tốt sau 31+ vòng audit trước** (crypto VIP đúng, lifecycle dispose sạch, không tìm thấy leak mới sau 3 agent + tự verify, 1553/1553 test pass, `flutter analyze` sạch). Nhưng **KHÔNG nên ship nguyên trạng cho user thật ở EEA/UK/CCPA** vì 2 BLOCKER consent ở trên — cả hai đều là lỗi thật đã tự verify qua source, không phải false positive.

**Điều kiện để dùng production:**
1. **Bắt buộc trước khi ship** — sửa BLOCKER-A (`ad_consent.dart`: chỉ set `_lastAppliedToProviders` sau khi từng provider write thành công) và BLOCKER-B (`iab_storage.dart`: đổi `on StateError` thành `catch (e)` phân loại lại `StateError` bên trong, để mọi lỗi đọc đều fail-closed).
2. Nếu target có AppLovin: chấp nhận không có Rewarded Interstitial parity (#2), và fix #7/#8 nếu dashboard doanh thu/CTR-fraud dựa vào AppLovin banner/MREC/native.
3. Nếu quảng cáo "hỗ trợ mọi quốc gia": phải tự làm thêm mapping GPP→doNotSell ở tầng host/CMP (#6), không coi SDK là zero-config đầy đủ cho US-state mới.
4. Trial/VIP: coi là entitlement local best-effort, không dùng cho giá trị tài chính thật trừ khi thêm backend.
5. Fix nhanh, rủi ro thấp, nên làm cùng đợt: #9 (hard-cap bootstrap), #11 (RI dialog gate), #15 (remote-config `min:1`), #10 (port fix example).

**So với agy/Gemini "APPROVED FOR PRODUCTION":** verdict đó dựa trên audit nông hơn, bỏ sót cả 2 BLOCKER — không nên dùng làm căn cứ quyết định.
