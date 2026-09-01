# Audit round 29 — deep adversarial re-audit (không diff-since-last-round)

**Ngày:** 2026-09-01
**HEAD tại thời điểm bắt đầu:** `6d6351d` (2.9.7, sau round 28)
**Lý do làm lại:** user chê round 28 (và ngầm 27 round trước đó) "quá vội vàng, bỏ sót quá nhiều" — round 28 chỉ diff-since-last-round + 3 CLI ~30 phút. Round này: 6 agent đọc **toàn bộ** từng subsystem từ đầu (không sample, không tin audit cũ), cấm dùng khung "so với round trước" — chỉ dùng khi đối chiếu để tránh báo trùng.
**Tổng thời gian agent:** ~50 phút (agent lâu nhất: core/state, 708s + 39 tool call, đọc hết `ad_manager.dart` 7468 dòng).
**Orchestrator (phiên này) đã tự verify bằng mắt** 3 finding nghiêm trọng nhất (2 BLOCKER core + 1 BLOCKER adapter) bằng cách đọc trực tiếp source trước khi đưa vào báo cáo — không có finding nào trong báo cáo này chỉ dựa vào lời agent nói suông.

---

## Kết quả: 3 BLOCKER + 6 MAJOR + 7 MINOR — phần lớn MỚI, chưa từng bị 28 round trước phát hiện

### BLOCKER

**B1 — `showRewardedAd()` không có try/catch/finally quanh 2 native call, có thể kẹt `_rewardedInFlight=true` vĩnh viễn**
`lib/src/core/ad_manager.dart:6546` (`_loadRewardedOnDemand`) và `:6598` (`await ad.showRewarded(...)`) không có try/catch. `_rewardedInFlight` chỉ được reset trong `onDone` callback hoặc các early-return đã liệt kê — nếu 1 trong 2 call này throw (native `PlatformException`, adapter bug, disposed platform view) thay vì gọi `onDone`, flag kẹt `true` mãi. Mọi `showRewardedAd()` sau đó (kể cả VIP watch-to-extend) báo "busy" vĩnh viễn tới khi `destroy()`+`initialize()` lại thủ công.
**Bằng chứng tự verify:** đọc trực tiếp dòng 6503-6628 — xác nhận đúng. Ironic: 3 dòng phía trên (6520-6524) chính code này TỰ NHẬN THỨC đúng loại lỗi này ở 1 chỗ khác (`AdLoadingDialog.show`) và đã fix, nhưng quên áp dụng cho 2 native call dễ throw nhất trong cùng hàm.

**B2 — `_disposeAdapter()`: `await old.dispose()` không có `.timeout()`, có thể kẹt `destroy()`/`initialize()` vĩnh viễn**
`lib/src/core/ad_manager.dart:5618` — có try/catch (bắt exception) nhưng KHÔNG có timeout (chặn hang). Nếu native SDK's `dispose()` không throw mà chỉ hang (chờ mãi không resolve), `_disposeAdapter()` không bao giờ return → `_destroy()` không bao giờ return → `_destroyInFlight` không bao giờ clear → mọi `initialize()` sau đó (kể cả từ retry timer) chờ vĩnh viễn. Đây CHÍNH XÁC là bug round 27 đã fix 2 lần trong cùng hàm này (`_eventStream.close().timeout(2s)` dòng 5320, `_eventLog?.flush().timeout(2s)` dòng 5422) nhưng bỏ sót lần thứ 3.
**Bằng chứng tự verify:** đọc trực tiếp dòng 5589-5622 — xác nhận đúng, không có `.timeout()` ở dòng 5618.

**B3 — `AppLovinAdapter` không có guard "disposed" cho callback load fullscreen (fix round 27 chỉ áp dụng cho AdMob, không port sang AppLovin)**
`lib/src/adapters/applovin_adapter.dart:981-999` (App Open), tương tự Interstitial/Rewarded — `onAdLoadedCallback`/`onAdLoadFailedCallback` chỉ check `_discardIfConsentStale`, KHÔNG check bất kỳ flag disposed/teardown nào (`_teardownStarted` tồn tại ở dòng 415 nhưng chỉ được đọc ở 1 chỗ khác, KHÔNG đọc trong các callback này — grep xác nhận). AdMob có guard này từ round 27 (`_fullscreenDisposed` check trong `onFailed`/`onLoaded`) nhưng AppLovin thì chưa bao giờ được áp dụng tương tự.
**Bằng chứng tự verify:** đọc trực tiếp dòng 975-1005 — `onAdLoadedCallback` không có check disposed nào trước `appOpenSlot.markReady()` + `_emit(...)`. Kịch bản: `dispose()` chạy giữa lúc 1 load đang in-flight → `eventSink=null` làm `_emit` no-op, nhưng `appOpenSlot.markReady()` vẫn chạy, mutate state 1 slot thuộc adapter đã bị teardown.

### MAJOR

**M1 — `ConsentManager.reset()` xóa nhầm cờ COPPA/CCPA, ngược hẳn doc comment của chính nó**
`lib/src/consent/consent_manager.dart:172-181` — doc nói "KHÔNG tự áp dụng lại cho provider", code gọi `_applyToProviders(config)` vô điều kiện. `ConsentSettings.unset` xóa TẤT CẢ field kể cả `isAgeRestrictedUser` (COPPA) và `doNotSell` (CCPA) — khác các mutator khác trong cùng file dùng `copyWith` để giữ nguyên field không liên quan. App child-directed gọi `reset()` (theo README:2163 mô tả là hành động vô hại "wipe state — next init re-prompts") sẽ vô tình tắt cờ COPPA và đẩy live cho AdMob ngay lập tức.

**M2 — Rate-limit "rapid resume" tự xóa counter khi vừa trip, vô hiệu hóa chính cap nó thực thi**
`lib/src/core/ad_safety_config.dart:672-683` — khi vượt `maxRapidResumesPerMinute`, code gọi `_resumeTimestamps.clear()` thay vì để sliding-window tự hết hạn (như cách CTR/click-spam check dùng). Kết quả: chỉ chặn được lần thứ N+1 của 1 đợt rồi reset về 0 — kẻ tấn công/lifecycle-loop lỗi có thể qua theo từng batch N vô hạn, thay vì bị giới hạn N/phút thật sự như log message tự claim ("wait up to 60s"). Không có lockout thật (khác 2 check chị em có `_triggerSuspiciousPause` 30 phút→24h).

**M3 — Banner AdMob tính adaptive width 1 lần lúc mount, không tính lại khi xoay màn hình/resize**
`lib/src/widget/banner_ad_widget.dart:151-154,183-184` — `_initBanner` chỉ chạy 1 lần (`_initStarted` không bao giờ reset). Xoay ngang/dọc, split-screen, hay unfold foldable không trigger load lại đúng width mới — banner giữ nguyên size cũ (lệch/hẹp) tới khi cả widget bị dispose+recreate (rời màn hình rồi quay lại). Chỉ ảnh hưởng AdMob — AppLovin dùng `isAdaptiveBannerEnabled: true` native-side, không bị.

**M4 — `AdaptiveAdSurface` debounce timer đã set trước khi fullscreen ad bật vẫn fire, phá vỡ đúng lời hứa doc comment của chính file**
`lib/src/adaptive/adaptive_ad_surface.dart:68-86` — doc comment (dòng 24-26) hứa "format đóng băng khi fullscreen ad chiếm màn hình". Nhưng `fullscreenBusy` chỉ được check LÚC ARM timer (dòng 69), không check lại LÚC timer fire (dòng 85). Kịch bản: xoay máy bắt đầu debounce 200ms; trong lúc đó fullscreen ad (App Open) bắt đầu hiện; 200ms sau timer vẫn fire, swap Banner↔Mrec — tháo dỡ + mount native view mới — ngay dưới màn hình đang bị fullscreen ad che, đúng cái "swap ẩn, phí ad request" mà doc nói là không thể xảy ra.

**M5 — AdMob banner/MREC khi navigate away chỉ ẩn widget, không thật sự pause refresh (bất đối xứng với AppLovin)**
`lib/src/widget/banner_ad_widget.dart:197-249`, `mrec_ad_widget.dart:173-225` — nhánh AppLovin gọi `setBannerRoutePaused`/`setMrecRoutePaused` (pause auto-refresh thật qua AdManager). Nhánh AdMob chỉ set `_admobIsTop=false` (đổi native view thành `SizedBox` placeholder cùng chiều cao) — KHÔNG gọi vào AdManager, vì Google Mobile Ads Flutter plugin không expose API pause runtime cho banner đã load. Native `BannerAd` object vẫn tự chạy timer refresh ngầm dù bị ẩn khỏi UI — tiếp tục tốn refresh/quota khi user đã navigate sang màn khác, đúng rủi ro policy "request ad không hiển thị" mà AdMob cảnh báo.

**M6 — Late native callback cross-cycle có thể "cướp" 1 lần show mới / mất reward — cả 2 adapter, ở Interstitial/Rewarded/RewardedInterstitial**
`admob_adapter.dart` (watchdog 10s vs real callback không check identity) và `applovin_adapter.dart` tương tự — App Open đã có fix (check `if (_appOpenDismiss == null) return;`) nhưng KHÔNG port sang 3 format còn lại, và ngay cả fix ở App Open cũng chưa đủ: chỉ chặn "chưa có gì mới bắt đầu", không chặn trường hợp 1 show mới ĐÃ gán lại field trước khi callback cũ trễ tới. Kịch bản tệ nhất: user xem xong rewarded ad #2 thật sự nhưng KHÔNG nhận thưởng, vì `_rewardedDone` đã bị ad #1 (watchdog timeout trước đó) tiêu thụ và null hóa.

### MINOR

- **m1** `consent_dialog.dart:34` `barrierDismissible: false` không chặn được nút back Android (thiếu `PopScope`) — không tạo fail-open (default vẫn conservative) nhưng phá vỡ ý đồ "buộc chọn" của UX.
- **m2** Ô nhập VIP redeem key không có `maxLength` — dán chuỗi rất lớn có thể khiến Ed25519 verify (pure-Dart, chạy UI isolate) giật máy yếu. Không bẻ khóa được, chỉ self-DoS cục bộ nhẹ.
- **m3** `top_toast.dart:136-153` — `await ctrl.reverse()` có thể treo vĩnh viễn nếu `dispose()` chạy đúng lúc đang reverse (toast mới đè toast cũ) — leak nhỏ closure/controller, verified chéo với Flutter SDK source (`Ticker.dispose()` không complete completer chính).
- **m4** `native_ad_widget.dart` — sau 1 lần load fail, `hasError` không bao giờ tự clear, native ad slot trống vĩnh viễn tới khi rời màn rồi quay lại (khác Banner/Mrec có nhiều đường hồi phục).
- **m5** `gma_bridge.dart:226-235` wiring `onImpression` đầy đủ ở tầng bridge nhưng adapter không bao giờ truyền `onImpression:` — dead code, không phải bug hành vi (impression vẫn đếm đúng qua đường khác).
- **m6** README chưa cảnh báo integrator về chính sách "ad density/không đặt banner sát nút bấm" của AdMob — SDK không thể tự enforce (đúng kiến trúc), nhưng nên có 1 đoạn cảnh báo.
- **m7** Nút "Reject" trong custom consent dialog (`consent_dialog.dart:209-240`) nhỏ hơn/mờ hơn nút "Allow" (flex 1 vs 2, ghost vs gradient) — cosmetic, không vi phạm chính sách vì dialog này KHÔNG phải CMP cho EEA (UMP form thật dùng UI mặc định của Google, không bị chỉnh sửa).

---

## Đối chiếu policy thật (WebFetch AdMob/UMP/AppLovin/Apple docs)

4/5 mảng đối chiếu đúng chính sách thật: test-device handling, AppLovin consent sync, ATT (SDK tự bundle + gọi đúng thứ tự, hơn cả brief giả định), COPPA→AppLovin gap (đã biết, đã document). Duy nhất gap thật: README thiếu cảnh báo ad-placement policy (m6 ở trên).

---

## Fix status (post-audit, same round, version 2.9.8)

User chose "fix hết" cho cả BLOCKER và MAJOR/MINOR. Kết quả, mỗi fix RED→GREEN mutation-verified thật (revert code → test đỏ đúng lý do → áp lại → xanh), không chỉ tin lời agent:

- **B1, B2, B3 — FIXED.** Try/catch quanh 2 native call trong `showRewardedAd`; `.timeout(2s)` cho `old.dispose()`; port `_fullscreenDisposed`-style guard sang AppLovin (dùng `_teardownStarted` có sẵn).
- **M1 — FIXED.** `ConsentManager.reset()` giữ nguyên `isAgeRestrictedUser`/`doNotSell` qua `copyWith`.
- **M2 — FIXED.** Bỏ `.clear()` khi rapid-resume trip, để sliding-window tự hết hạn tự nhiên.
- **M3 — FIXED.** `BannerAdWidget` track `_admobWidthPx`, dispose+reload khi width đổi thật (rotation/resize).
- **M4 — FIXED.** `AdaptiveAdSurface` recheck `AdManager().fullscreenBusy.value` (đồng bộ, không dùng `stateSnapshot` bị trễ 1 microtask) ngay lúc debounce timer fire.
- **M5 — FIXED.** Banner/Mrec route-away giờ dispose thật + reload khi quay lại (AdMob), thay vì chỉ ẩn widget.
- **M6 — FIXED một phần.** AdMob: thêm `cycleEnded` local flag (không dùng so sánh field instance — tránh đúng cái bug em tự gây ra khi lẫn lộn "null vì đã tự resolve cùng cycle" với "null vì cycle khác chiếm") cho Interstitial + Rewarded. **AppLovin: KHÔNG fix round này** — kiến trúc AppLovin dùng 1 listener persistent/loại ad (wire lúc `initialize()`), không phải closure riêng mỗi lần `show()` như AdMob, nên cần ad-identity tracking (`identical(ad, _interstitialAd)`) thay vì local flag. Đã thử implement đầy đủ (4 identity-guard cho interstitial + rewarded), nhưng **phá 14+ test có sẵn** vì toàn file `applovin_adapter_test.dart` dùng `_fakeAd()` tạo instance MỚI mỗi lần gọi thay vì tái dùng 1 object xuyên suốt load→show→hide (khác thực tế native SDK). Sửa an toàn đòi hỏi rewrite quy ước đó trên diện rộng — rủi ro cao, revert, để lại làm follow-up riêng.
- **m1 → m7 — FIXED cả 7.** Riêng m3 (TopToast leak) chỉ verify được cơ chế `.orCancel` độc lập (không qua được `_animateOut` thật vì leak dạng Future treo không quan sát được qua `pumpAndSettle`) — ghi rõ giới hạn này, không tự nhận verify đầy đủ hơn thực tế.

**Verify cuối:** `flutter analyze` 0 issues, `flutter test` 1503/1503 pass (từ 1482 baseline round 28 → +21 test mới cho round 29, không test nào bị xóa/skip).

## Verdict round 29 (trước fix) → sau fix

Trước fix: **hạ tin cậy so với round 28** (3 BLOCKER availability + 6 MAJOR thật, phần lớn mới). 3 BLOCKER đều là bug khả dụng (SDK tự làm liệt 1 phần/toàn bộ dưới điều kiện hiếm nhưng có thật — native platform-channel throw/hang), không phải mất dữ liệu hay lỗ hổng bảo mật, nhưng đủ nghiêm trọng để chặn production tới khi vá.

**Sau fix (v2.9.8):** cả 3 BLOCKER + 5.5/6 MAJOR (AdMob side đầy đủ, AppLovin side của M6 còn treo) + cả 7 MINOR đã vá, RED→GREEN verify thật, 1503/1503 test xanh. **Ready for production use: YES WITH CONDITIONS** — điều kiện duy nhất còn lại ngoài BLOCKER key-rotation cũ (risk-accepted, ngoài phạm vi code): AppLovin's Interstitial/Rewarded vẫn có gap cross-cycle late-callback lý thuyết (M6) chưa vá — thấp khả năng xảy ra thực tế (cần watchdog timeout + reload + show lại đúng lúc native event trễ tới), nhưng là follow-up thật, không phải "coi như xong".

**Bài học phương pháp (đã lưu vào memory):** 28 round trước không hời hợt về mặt effort, nhưng bị bias bởi khung "diff since last round" — hội tụ vào đúng 1 checklist, đúng 1 vùng gần nhất mới đổi. Round 29 chỉ đổi cách hỏi (đọc lại từng subsystem từ đầu, cấm dùng "so với trước") mà tìm ra gấp 6 lần số finding thật của round 28, dùng agent/thời gian nhiều hơn nhưng không phải công nghệ mới — chỉ là hỏi đúng câu hỏi.
