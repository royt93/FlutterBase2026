Audit round 31 — full re-audit từ đầu, toàn bộ lib/src/ + example/

**Ngày:** 2026-09-02
**HEAD tại thời điểm bắt đầu:** `bcaa5f0` (2.9.10, sau round 30)
**Bối cảnh:** user yêu cầu audit lại TOÀN BỘ SDK + demo app, ưu tiên AdMob
provider, sau khi đặt câu hỏi phương pháp luận trực tiếp: tại sao audit
liên tục ra bug mới, làm sao để có "final version". Thay vì tin round
29-30 đã đạt "full coverage" là đủ, user chọn full re-audit từ đầu cho cả
những phần round 29-30 vừa đọc kỹ — kết quả xác nhận lo ngại của user là
đúng: đọc lại VẪN ra bug thật, kể cả 1 BLOCKER nằm trong `admob_adapter.dart`
mà round 29 đã audit qua.

## Phương pháp

9 agent song song, mỗi agent đọc hết 1 vùng từ đầu, không tin bất kỳ audit
report cũ nào trong `doc/audit/`, dùng WebFetch tra chính sách
Google/Apple/AppLovin mới nhất khi cần đối chiếu. Ưu tiên đặc biệt: 1 agent
riêng cho AdMob adapter (đối chiếu policy Google Flutter Targeting guide),
1 agent riêng cho `example/` app (CHƯA từng có agent nào đọc riêng qua 30
round trước).

## Kết quả: 2 BLOCKER + ~20 MAJOR + ~6 MINOR thật, 2 false positive

### BLOCKER 1 — AdMob COPPA/TFUA flags gọi sau `MobileAds.instance.initialize()`
`admob_adapter.dart` — `updateRequestConfiguration()` (mang cờ
`tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent`) gọi SAU
`_bridge.initialize()`. Google Flutter Targeting guide yêu cầu ngược lại
("ensure all ad requests apply the request configuration changes"), và
đây là chính SDK này đã TỰ SỬA đúng cho AppLovin (MJ1) mà không port sang
AdMob. Mediation network con (Meta, Unity...) init bên trong
`initialize()` có thể gửi request đầu tiên thiếu cờ trẻ em — rủi ro COPPA/
Play Families thật. **Fix:** đổi thứ tự gọi.

### BLOCKER 2 — iOS TCF read path chưa verify trên máy thật, fail-open khi lỗi
`iab_storage.dart` tự thừa nhận "Verified on Android hardware. iOS branch
... has NOT been exercised on a device — CI down since 2026-08-09."
`tcfAllowsPersonalisedAds()` không phân biệt "chưa từng có TCF session"
(null hợp lệ, mặc định `true`) với "platform store đọc lỗi thật" (cũng
null trước đây, cũng mặc định `true` — nguy hiểm). Nếu store đọc sai âm
thầm trên iOS thật, tái phát đúng BLOCKER round-6 (obtained = đủ để bật
personalized ads dù EEA user từ chối). **Fix:** đọc trực tiếp qua `_open()`,
bắt riêng `StateError` ("không platform implementation nào đăng ký" — chỉ
xảy ra trong test harness, không thể xảy ra trên app thật) khác với mọi
exception khác (fail-closed).

### MAJOR — core/ad_manager.dart, ad_safety_config.dart (7 finding)
1. `disableFillRateBaselineMonitor()` copy-paste sai từ `destroy()`, tắt
   luôn 3 tính năng opt-in khác không liên quan.
2. `_attachFullscreenDismissWatchers()` thiếu `rewardedInterstitialSlot`.
3. `refreshRemoteSafetyParams()` thiếu try/catch + `posInt()` throw trên
   Infinity — payload remote hỏng có thể crash.
4. Daily cap dùng ngày lịch LOCAL, đổi múi giờ thiết bị reset counter tuỳ
   ý (không cần chỉnh đồng hồ).
5. CTR-anomaly tự khoá vĩnh viễn — show bị chặn không tính impression để
   pha loãng ratio, retrigger ngay lập tức với ratio cũ sau mỗi pause.
6. (MINOR) exponent clamp khiến pause tối đa 24h không bao giờ đạt (thực
   tế 8h).
7. Decay math cho violation count không clamp `hoursSince` âm — clock
   rollback khuếch đại thay vì giảm.
8. (MINOR) `unitDouble` CTR threshold chấp nhận `0.0`.

Tất cả đã fix, RED→GREEN mutation-verified. Chi tiết đầy đủ trong CHANGELOG
2.9.11.

### AdMob adapter (2 finding, 1 MAJOR + 1 MINOR)
Banner/MREC/native chưa từng wire `onAdImpression` thật (dùng `onAdLoaded`
làm proxy — fill ≠ impression), không emit `AdImpressionEvent` cho 3 định
dạng, méo mẫu số CTR-fraud. Banner/MREC dùng `onAdOpened` cho click, native
dùng `onAdClicked` — 2 event Google tài liệu hoá khác nhau.

### AppLovin adapter (2 MAJOR + 2 MINOR, 2 false positive)
App Open thiếu ad-identity tracking (round-29 chỉ áp cho Interstitial/
Rewarded); remote override thiếu 2 field T126; doc comment sai 1 chỗ.
**False positive:** `incrementDailyAdCount`/`incrementPlacementDailyCount`
write-chain (Dart đơn luồng + `SharedPreferences` cache đồng bộ = không có
race thật — verify bằng cách thêm chain THẬT rồi thấy PHÁ 6 test dựa vào
tính đồng bộ, mới nhận ra); widget listener thiếu `_teardownStarted` guard
(`_bannerDisposed`/`_mrecDisposed` đã tự bảo vệ qua scratch-object — verify
bằng race test thật với `_TeardownRaceBridge`, thấy KHÔNG mutate).

### VIP (1 MAJOR thật + 2 documented-as-accepted-risk + 1 MINOR doc)
`RedeemedKeyLedger._writeChain` instance-level thay vì static — mirror
đúng bug pattern `VipManager._saveQueue` đã sửa ở round-10 nhưng bỏ sót ở
đây. `AdManager` không truyền lại ledger cũ khi destroy+reinit → 2 instance
ghi đè Keychain → redeem lại được key cũ sau reinstall. **Fix:** static,
mirror `_savesInFlight` pattern.

High-water-mark clock + redeemed-kid-list trên Android đều plain
`SharedPreferences` — **KHÔNG thêm checksum**: lịch sử audit repo này (M6)
đã chứng minh checksum không-khoá với salt trong source published không
bảo vệ thật trước kẻ tấn công root/physical-extraction cần chặn. Ghi nhận
là giới hạn chấp nhận được của kiến trúc "không backend", không phải bug
để "sửa" bằng giải pháp giả.

### Widget (3 MAJOR + 1 MINOR)
Splash controller buffer callback thiếu check `_navigated` (App Open có
thể show sau khi đã navigate); NativeAdWidget retry listener chết sau bất
kỳ dispose/revive cycle nào (consent gate đóng-mở); banner/MREC chỉ dựa
RouteAware, không phủ IndexedStack/Visibility(maintainState) — thêm
TickerMode detection (ghi rõ IndexedStack trần vẫn không phủ được).

### Monetization — chỉ tài liệu hoá
`WaterfallTuner`/`SelfHealingObserver` không bao giờ trả recommendation
non-null trên thiết bị thật (kiến trúc 1 install = 1 provider cố định).
Đã opt-in sẵn — ghi rõ giới hạn vào doc, không đổi hành vi.

### Consent/GDPR/COPPA/CCPA (2 MAJOR + 1 MINOR + 1 tính năng mới)
ATT prompt thiếu mutex on-screen như UMP form (tái dùng chính xác
`markUmpFormOnScreen`, không xây cơ chế song song). Thiếu cảnh báo COPPA/
UMP-under-age mismatch (`coppaUmpMismatchWarning`, cùng hợp đồng
`consentFootgunWarning`). Doc comment lỗi thời (package `umpsdk` không tồn
tại). **Tính năng mới theo yêu cầu user:** `CcpaOptOutToggle` widget cho
CCPA "Do Not Sell" — máy móc backend đã đúng từ trước, chỉ thiếu UI thật.

### Example app — lần đầu có ai đọc riêng (3 MAJOR)
`mrecId` dùng nhầm test-ID Native Advanced (phải dùng Banner ID); thiếu
`rewardedInterstitialId` (trang demo riêng round-27 làm không bao giờ
show được ad thật); `AppOpenDemoPage` dùng context sau async gap không
check `mounted` — code mẫu dễ bị app khác copy nguyên lỗi.

## Verify cuối
`flutter analyze` 0 issues (cả SDK lẫn example), `flutter test` 1553/1553
(SDK) + 28/28 (example unit/widget). Mỗi fix RED→GREEN mutation-verified
thật.

## Bài học phương pháp round 31

1. **Full re-audit từ đầu (kể cả phần vừa audit kỹ) vẫn ra bug thật** —
   xác nhận đúng lo ngại ban đầu của user. BLOCKER 1 nằm trong file round
   29 đã cử hẳn 1 agent đọc riêng, vẫn bị bỏ sót vì round 29's agent không
   đối chiếu TỪNG DÒNG với policy Google gốc, chỉ đọc logic code.
2. **2 false positive bị bắt bằng cách tự verify sâu, không chỉ tin agent
   report** — cả 2 đều là agent pattern-match đúng "hình dạng" 1 bug đã
   biết (T101 write-chain, round-29's `_teardownStarted` guard) mà không
   verify CƠ CHẾ LƯU TRỮ/GUARD THỰC TẾ có khác gì so với case gốc. Bài
   học: một finding "giống bug đã biết" cần verify riêng, không suy diễn
   từ tiền lệ.
3. **Không phải mọi finding đều nên "sửa"** — VIP checksum bị từ chối vì
   lịch sử audit CHÍNH repo này (M6) đã chứng minh giải pháp đó không bảo
   vệ thật; WaterfallTuner giữ nguyên + chỉ tài liệu hoá vì đây là giới
   hạn kiến trúc, không phải lỗi code.

## Trả lời câu hỏi "final version" của user

Không có "0 bug tuyệt đối" cho SDK quy mô này. Nhưng sau round 31: đã đọc
hết TOÀN BỘ `lib/src/` + `example/` ít nhất 2 LẦN theo kiểu "không tin
baseline" (round 29-30 lần 1, round 31 lần 2) — bằng chứng: round 31 tìm
được bug THẬT ở round 29-30's coverage, không phải vùng mù mới. Điều này
xác nhận: bug tiếp tục xuất hiện không phải vì code liên tục xấu đi, mà vì
việc đọc-lại-với-góc-nhìn-khác luôn tìm được cái mà lần trước bỏ sót — kể
cả khi lần trước đã "kỹ". Định nghĩa "đủ ổn định" thực tế: coverage đã đạt
2 lần độc lập, CI xanh, giờ nên chuyển sang review-khi-có-thay-đổi-thật +
verify device thật (integration test CI vẫn chưa chạy do billing — xem
audit-round26-blocker-key-rotation.md) thay vì tiếp tục audit-lại-toàn-bộ
vô hạn.

## Verdict
Không BLOCKER mới sau fix. **YES WITH CONDITIONS** không đổi so với round
29-30 — điều kiện còn lại: BLOCKER key-rotation cũ (ngoài phạm vi code,
risk-accepted), và verify thực tế trên device thật (chưa từng chạy CI
integration do billing) vẫn là khoảng trống lớn nhất còn lại, lớn hơn khả
năng tìm thêm bug qua audit vòng 32.
