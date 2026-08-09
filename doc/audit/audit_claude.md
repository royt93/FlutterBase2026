# Audit độc lập — `applovin_admob_sdk` (packages/ad_sdk)

**Người audit:** Claude (Sonnet 5), agent độc lập
**Ngày:** 2026-08-09
**Phương pháp:** đọc code từ đầu trong repo này, KHÔNG xem trước `audit_claude.md` cũ, `audit_gemini.md`, `audit_codex.md`. Xác minh bằng `git log`/`git diff`, `flutter analyze`, `flutter test`, đọc trực tiếp source SDK + cách host app (`saigonphantomlabs`) tích hợp.

**Version:** local `packages/ad_sdk/pubspec.yaml` = `2.0.3`. pub.dev latest = `2.0.3` (published `2026-08-09T13:21:42Z`, cùng ngày audit). **Không lệch version.** Host app (`pubspec.yaml` root) dùng path override cục bộ tới `packages/ad_sdk` — cần xác nhận lại dòng nào đang active trước khi release (theo CLAUDE.md, hosted vs path override phải flip đúng lúc ship).

**Test suite:** `flutter test` tại `packages/ad_sdk` → **699/699 pass**. `flutter analyze` → **0 issues**.

---

## Bảng checklist 7 tiêu chí

| STT | Tiêu chí | Đạt/Không/Gap | Bằng chứng |
|---|---|---|---|
| 1 | Provider AdMob/AppLovin, work Android+iOS | **Đạt** | `ad_manager.dart:1307` chọn adapter theo `config.isAdMob`; cả `AdMobAdapter` và `AppLovinAdapter` implement chung `AdProviderAdapter` interface (`ad_provider_adapter.dart`). Android manifest có đủ `APPLICATION_ID`, `applovin.sdk.key`, `AD_ID`, `INTERNET`, `ACCESS_NETWORK_STATE` (`android/app/src/main/AndroidManifest.xml:5-6,11,53,59`). iOS `Info.plist:52-59` có đủ `GADApplicationIdentifier`, `AppLovinSdkKey`, `NSUserTrackingUsageDescription`, `SKAdNetworkItems`. Ad unit ID trong `lib/mckimquyen/common/const/ad_keys.dart` là ID **production thật** (không phải test ID `ca-app-pub-3940256099942544...`), có `assert` chặn debug/test build nếu lỡ dùng test ID (`splash_screen.dart:364-372`). |
| 2 | Work có mạng / không có mạng | **Có gap** | `ad_manager.dart:1975` có `isConnected` getter với fallback `_lastConnected` khi đọc trước ready; adapter gate `canReload` (`ad_manager.dart:1312-1316`) chặn load ad khi mất mạng — tốt. Nhưng **`VipManager.redeemSignedKey` giờ bắt buộc có mạng** (`vip_manager.dart:599-603`) dù xác minh chữ ký Ed25519 hoàn toàn offline — mâu thuẫn với chính mô tả package trên pub.dev ("**Offline VIP redeem**"). Người dùng offline (máy bay, vùng sóng yếu) không redeem được VIP key dù đã có key hợp lệ trong tay. Xem Finding M1. |
| 3 | Chuẩn ad type (banner/app-open/inter/reward): pháp lý, vòng đời, không leak | **Đạt** | Mutex fullscreen dùng chung 1 predicate `_fullscreenBusyReason` (`ad_manager.dart:632-652`) — trước đây mỗi path (`showAppOpenAdOnResume`/`showInterstitial`/`showRewarded`) tự check riêng và bị lệch nhau, có thể chồng 2 quảng cáo toàn màn hình (vi phạm chính sách AdMob/AppLovin) — đã fix và có test seam `debugFullscreenBusyReason`. Timer: `_initRetryTimer`, `_hardCapTimer` (splash), `_expiryTimer` (VIP) đều được cancel đúng chỗ trong `destroy()` (`ad_manager.dart:1874-1875`) và trong `_navigateToMainSafely()`/`dispose()` của `SplashScreen` (`splash_screen.dart:398,415`). `EventBus` listener remove đúng 1 lần cả ở navigate lẫn dispose — không leak listener. `onComplete` giờ đảm bảo gọi đúng 1 lần/call host-initiated (fix trong diff `ad_manager.dart` quanh dòng 1334-1350, xem CHANGELOG 2.0.1). |
| 4 | Trial mode 1 ngày | **Đạt** | `FirstInstallVipGrace.auto = kDebugMode ? debugShort(30s) : day(Duration(days:1))` (`ad_config.dart:43-53`). Host không override (`splash_screen.dart:355-356` giữ default). Release build = đúng 24h grace cho user mới cài. |
| 5 | VIP by code, bảo mật, không backend | **Đạt, có 1 gap nhỏ** | Ed25519 verify hoàn toàn offline (`signed_vip_key.dart`), chỉ public key ship trong app (`vip_keys.dart:15-16`), khoá riêng của app production tách biệt khỏi demo key của SDK example (comment rõ trong `vip_keys.dart:9-12`) — đúng thực hành. AVP2 format thêm expiry + bundle-id binding trong payload đã ký (`signed_vip_key.dart:66-84`) — tốt, chặn key rò rỉ dùng mãi mãi hoặc dùng sai app. Rotation nhiều public key qua danh sách phẩy (`signed_vip_key.dart:131-168`) cho phép thu hồi key bị lộ mà không phá key cũ còn hợp lệ. **Gap:** yêu cầu mạng để redeem (M1 ở trên) là quyết định sản phẩm, không phải giới hạn kỹ thuật — nên cân nhắc lại vì làm sai lệch tính năng "offline". |
| 6 | Consent mọi quốc gia (GDPR/CCPA/COPPA/ATT), UMP + AppLovin CMP | **Đạt** | UMP là nguồn consent chính (`autoRequestUmpConsent` default `true` từ 2.0.0, `ad_config.dart:349`), AppLovin CMP bị tắt để tránh double-prompt (`disableAppLovinCmpFlow: true` default, `ad_config.dart:353`, áp dụng ở `applovin_adapter.dart:203-208`). ATT chạy trước UMP trên iOS đúng thứ tự Apple yêu cầu (`splash_screen.dart:231-247`, log-only order-check trong SDK ở `ad_manager.dart:1696-1704`). CCPA: `doNotSell` propagate vào `restrictedDataProcessing` cho AdMob (`admob_adapter.dart`, test `admob_behavioral_test.dart` cover RDP riêng biệt với personalization). COPPA: `isAgeRestrictedUser=true` khiến AppLovin **không init luôn** thay vì init sai cấu hình (`applovin_adapter.dart:179-186`) — bảo thủ, an toàn về pháp lý. Host app truyền `consentDialogStrings` bằng bản dịch vi/en thật (`splash_screen.dart:326-333`), không phải string tiếng Anh cứng. |
| 7 | Tuân thủ policy AdMob/AppLovin | **Đạt, có 1 risk chấp nhận đã ghi nhận** | Daily/hourly/session cap + 30 phút suspicious pause + escalate tới 24h (`ad_safety_config.dart:227-228`), throttle, CTR fraud check đều tồn tại và có test riêng (`daily_cap_load_gate_test.dart` v.v., nằm trong 699 test). `bypassSafety: true` **chỉ** dùng cho App Open ở splash cold-start — đúng như CLAUDE.md mô tả, và bản thân code đã tự ghi chú đây là risk đã được chủ dự án chấp nhận + có first-install VIP grace 24h giảm thiểu (`splash_screen.dart:155-166`, quyết định ghi ngày 2026-07-16). `_fullscreenBusyReason` (mục 3) đóng thêm 1 lỗ hổng policy (chồng ad toàn màn hình). |

---

## Findings chi tiết (theo severity)

### High

**H1 — App Open cold-start `bypassSafety: true` là risk đã biết nhưng vẫn là risk thật.**
`splash_screen.dart:155-166`. AdMob Policy Center coi App Open che nội dung ngay lần mở app đầu tiên là vùng xám chính sách. Code đã tự ghi rõ đây là quyết định có chủ đích (ngày 2026-07-16), giảm thiểu bằng 24h first-install VIP grace (App Open không hiện ngày đầu vì user đang ở trong grace VIP). Đánh giá: chấp nhận được nếu owner đã quyết, nhưng **cần theo dõi AdMob Policy Center định kỳ** như comment đã nói — không phải "để đó luôn".
*Kịch bản thất bại:* nếu Google policy siết lại đúng pattern App Open cold-start, tài khoản AdMob có thể bị cảnh cáo/suspend hàng loạt account, không chỉ app này.

### Medium

**M1 — `VipManager.redeemSignedKey` yêu cầu mạng dù việc xác minh 100% offline, mâu thuẫn với mô tả "Offline VIP redeem" trên pub.dev.**
`vip_manager.dart:588-603`, đối chiếu `pubspec.yaml:6` (description) và `pub.dev` package description hiện tại. Đây là quyết định sản phẩm có chủ đích (chống chia sẻ 1 key cho nhiều máy) nhưng tên tính năng public-facing đang nói ngược lại hành vi thật.
*Kịch bản thất bại:* user có key hợp lệ, network chập chờn/máy bay/vùng sóng yếu → không redeem được, thấy thông báo lỗi mạng cho 1 chức năng quảng cáo là "offline".
*Khuyến nghị:* hoặc sửa mô tả package (bỏ chữ "Offline"), hoặc cho phép redeem offline rồi xác nhận network sau (soft-gate thay vì hard-block).

**M2 — Android + iOS dùng chung 1 AdMob App ID (`ca-app-pub-3004713799155145~9488250427`).**
`android/app/src/main/AndroidManifest.xml:54` và `ios/Runner/Info.plist:53` giống hệt nhau. Theo lịch sử commit (`2a58b45`) đây đã được owner xác nhận là **chủ đích** (1 app registration cho cả 2 platform). Ghi nhận lại ở đây để bất kỳ ai audit sau không tưởng nhầm là bug — nhưng nếu app thật ra được đăng ký AdMob riêng cho Android/iOS (2 App ID khác nhau) thì đây là misconfig nghiêm trọng làm mất hết revenue/attribution ở 1 platform. Cần double-check trực tiếp trong AdMob console, không chỉ tin theo commit message.

**M3 — `autoRequestUmpConsent` default đổi `false → true` (2.0.0) là breaking behavior cho các host khác đang dùng SDK.**
`ad_config.dart:349`. Đúng với host app này (đã verify: `splash_screen.dart` tự gọi `requestUmpConsent()` trước, cơ chế `skipIfAlreadyRequested` trong `ad_manager.dart:1667-1690` tránh double-run — đã trace kỹ, an toàn cho pattern hiện tại của host). Nhưng đây là **thay đổi default hành vi** ảnh hưởng bất kỳ consumer nào khác của package public trên pub.dev mà chưa update code theo pattern mới — không phải bug trong repo này, nhưng đáng lưu ý cho SemVer/CHANGELOG khi có consumer ngoài.

### Low

**L1 — Bounded init-retry (3 lần, 5s/15s/30s) không có giới hạn trên tổng số session, chỉ giới hạn theo attempt counter reset mỗi lần host gọi `initialize()` thủ công.**
`ad_manager.dart:505-520,1449-1476`. Nếu host tự động gọi lại `initialize()` định kỳ (ví dụ mỗi lần app resume) trong lúc network liên tục chập chờn, retry budget reset liên tục → về lý thuyết có thể lặp gọi native SDK init nhiều lần trong thời gian ngắn hơn ý đồ "cho next launch nghỉ". Không thấy code host app hiện tại làm vậy (chỉ gọi 1 lần ở splash), nên rủi ro thực tế thấp — ghi nhận để theo dõi nếu sau này có thêm call site gọi `initialize()`.

**L2 — `maxVipStackDuration` default đổi từ `null` (uncapped) sang `Duration(days: 90)` (2.0.0), áp dụng cho *cả* stacking lẫn non-stacking path** (`ad_config.dart:340-357`, `vip_manager.dart` `addVip`).
Đây là siết chặt bảo mật tốt (chặn 1 key rò rỉ cấp VIP vĩnh viễn), và host app đã tự set tường minh `maxVipStackDuration: const Duration(days: 90)` (`splash_screen.dart:338-340`) nên hành vi không đổi với app này dù default SDK có đổi hay không. Không phải risk cho repo này — nhưng cần nhớ nếu sau này ai đó xoá dòng set tường minh này, hành vi vẫn giữ nguyên nhờ default mới (không phải regression).

---

## Đánh giá thay đổi gần đây (từ `e634297` đến `HEAD`, phạm vi `packages/ad_sdk/lib`)

Đã đọc full diff 11 file thay đổi (814 dòng thêm / 109 dòng xoá). Tổng quan chất lượng: **cao, có kỷ luật**. Mỗi thay đổi có comment giải thích rõ *tại sao* (không chỉ *cái gì*), trích dẫn số CI run cụ thể khi liên quan tới race condition đã quan sát thực tế (ví dụ comment trong `ad_manager.dart` về `runZonedGuarded` dẫn CI run `30749745112`). Xác nhận không có regression rõ ràng:

- **Init auto-retry + `_isInternalInitRetryCall` flag**: đọc kỹ thứ tự đọc/xoá flag trước early-return guard (`ad_manager.dart:1024-1029`) — đúng, tránh flag bị kẹt `true` vĩnh viễn nếu retry timer bắn trúng lúc có call khác đang giữ `_isInitializing`.
- **`onComplete` gọi đúng 1 lần**: `_scheduleInitRetryIfNeeded` trả `bool` để caller quyết định có tự báo `onComplete` hay để retry lo — logic đúng, đã có test.
- **UMP chạy concurrent qua `runZonedGuarded`, không `await`**: đây là fix quan trọng nhất trong đợt này (C1) — trước đó UMP block `initialize()` tới 20s nếu form consent đứng yên. Cách xử lý (đóng gate `_canRequestAds=false` trước, mở lại khi UMP xong hoặc lỗi) là đúng hướng và đã trace không có race thực sự (xem phần suy luận UMP double-run ở M3) vì `requestUmpConsent`'s skip-branch chạy đồng bộ trước await đầu tiên.
- **`canReload()` gate ở 5 entry point banner/mrec/native + `onAppResumed`, cả 2 adapter**: đọc đối chiếu — trước đó chỉ fullscreen ad có gate, banner/mrec/native có thể tự load bất chấp VIP/consent/daily-cap sau khi resume app. Fix đúng, đối xứng giữa AdMob và AppLovin adapter (không có adapter nào bị bỏ sót).
- **Clock-rollback guard `_effectiveNow()`**: áp dụng nhất quán ở `expiresAt`, `_refreshGraceNudge`, `_purgeExpired`, `_refreshActive`, `_scheduleNextExpiry`, `addVip` — đã rà từng call site, không còn chỗ nào đọc `DateTime.now()` trực tiếp cho tính "active" (chỉ còn `VipEntry.isActive`/`remaining` convenience getter cho test, có ghi chú rõ). Giới hạn đã biết: không bắt được rollback *trước lần chạy đầu* (không có high-water mark cũ) — đã ghi rõ trong docstring, chấp nhận được vì là giới hạn cố hữu của cơ chế client-side.
- **AVP2 signed key + rotation nhiều public key**: đọc kỹ vòng lặp verify từng key trong danh sách phẩy (`signed_vip_key.dart:143-169`) — 1 key hỏng format không làm hỏng cả danh sách (dùng `continue`, không throw sớm). Payload field count đúng theo version (2 field AVP1, 4 field AVP2). Bundle-id check cho phép nhiều id phẩy (đúng vì app có 2 bundle id khác nhau Android/iOS, đã ghi trong comment).
- **`isConnectedCheck` inject vào `VipManager`**: default `() => true` (fail-open) khi không ai wire — đúng để không phá test cũ/host cũ. Production path wire đúng `() => isConnected` từ `AdManager` (`ad_manager.dart:1121`).

Không phát hiện race condition mới, không phát hiện leak mới trong phạm vi diff này.

---

## Kết luận cuối

**SDK này CÓ THỂ dùng cho production app** — nhưng với 1 điều kiện cần làm rõ trước khi công bố rộng: sửa mô tả "Offline VIP redeem" (M1) cho khớp hành vi thật, hoặc nới lỏng gate mạng. Phần còn lại (consent, ad lifecycle, trial, policy compliance, code quality của các fix gần đây) đều đạt chuẩn production, có test coverage tốt (699/699 pass, `flutter analyze` sạch), và các quyết định rủi ro (App Open cold-start bypassSafety) đều được ghi nhận có chủ đích thay vì bị bỏ sót.

**Điểm tổng: 8/10.**
Trừ điểm chủ yếu vì: (1) mâu thuẫn giữa mô tả "offline" và hành vi thật (M1) — ảnh hưởng trực tiếp trải nghiệm người dùng thật sự offline; (2) App Open cold-start vẫn là vùng xám chính sách chưa có kế hoạch giảm thiểu dài hạn ngoài "theo dõi Policy Center" (H1); (3) cần xác nhận lại ngoài AdMob console rằng dùng chung App ID Android/iOS thực sự đúng ý đồ, không phải nhầm lẫn cũ chưa phát hiện (M2).

**Rủi ro cao nhất nếu ship ngay bây giờ, theo severity:**

1. **High — H1:** App Open bypassSafety ở cold-start có thể bị AdMob Policy Center gắn cờ nếu chính sách siết lại; ảnh hưởng cả tài khoản AdMob, không chỉ 1 app.
2. **Medium — M1:** User offline không redeem được VIP key hợp lệ, ngược với tính năng quảng cáo chính của package.
3. **Medium — M2:** Rủi ro về xác nhận App ID dùng chung Android/iOS — cần double-check trực tiếp AdMob console, không chỉ tin commit message cũ.
4. **Medium — M3:** Default `autoRequestUmpConsent=true` là breaking change cho consumer khác của package public — không ảnh hưởng app này nhưng cần CHANGELOG rõ ràng nếu SDK được dùng rộng hơn 1 app.
5. **Low — L1, L2:** không ảnh hưởng thực tế tới app này ở trạng thái hiện tại, chỉ cần theo dõi nếu pattern sử dụng thay đổi.
