# Audit round 28 — độc lập (Claude)

**Ngày:** 2026-09-01
**Commit HEAD tại thời điểm audit:** `d3da1bc` (version 2.9.6)
**Bối cảnh:** 2 commit kể từ round 27 (`d25e43d`) — 1 docs (`6784858`, đóng gap
MREC/Native/RewardedInterstitial trong `AD_PROMPT_FLUTTER.MD`), 1 test fix
(`d3da1bc`, integration test). **Không commit nào chạm `lib/`.** Đây là audit
tươi, độc lập, tự dựng lại finding từ source hiện tại, không rubber-stamp
round 27 — theo đúng brief.

**Phương pháp:** đọc `audit_round27_consolidated.md` làm baseline, tự chạy
`flutter analyze` + `flutter test`, sau đó dispatch 6 investigation song song
vào từng vùng rủi ro brief yêu cầu soi kỹ (adapter dispose/teardown race, VIP
ledger concurrency, consent/UMP edge case, AppOpen stacking trên dialog,
banner RouteAware leak, trial-mode clock manipulation) cộng 1 việc riêng
check đồng bộ pub.dev. Mỗi investigation đọc source thật, cross-check với
round 26/27 để phân biệt finding cũ vs mới, và verify chéo file
`doc/task/PROPOSALS-claude-2026-08-31.md` (roadmap tự đề xuất hôm trước) thay
vì tin theo lời báo cáo đó. Sau khi 6 investigation xong, tôi đọc thêm
`audit_codex_round28.md` và `audit_agy_round28.md` (đã có sẵn trên đĩa — 2
reviewer độc lập khác chạy cùng batch) để đối chiếu, không phải để copy.

---

## 1. Kiểm chứng thực chạy

```
flutter analyze   → No issues found! (ran in 5.0s)
flutter test      → All tests passed! (+1482, 0 fail)
```

1482/1482 khớp con số round 27 ghi nhận cuối round (1.482/1.482) — không
regression, không test mới nào bị bỏ sót kể từ round 27 (dự đoán đúng, vì
không có commit `lib/` nào ở giữa). Không chạy lại
`example/integration_test/` (cần emulator/simulator thật) — không cần thiết
vì round 27 đã verify bộ này cuối round và không commit `lib/`/`example/lib`
nào can thiệp kể từ đó; commit test fix duy nhất (`d3da1bc`,
`rewarded_interstitial_ad_test.dart`) tự nó là sửa 1 file integration test,
không phải regression.

## 2. Đối chiếu 7 yêu cầu sản phẩm

| # | Yêu cầu | Kết quả | Ghi chú |
|---|---|---|---|
| 1 | AdMob + AppLovin, Android + iOS | ✅ PASS | Không đổi so với round 27, không commit `lib/` nào giữa 2 round. |
| 2 | Có mạng / không mạng | ✅ PASS | Không đổi. |
| 3 | 7 loại ad, lifecycle, no-leak | ⚠️ PASS-with-caveat | **1 MAJOR mới** (App Open stack trên bottom sheet ở app dùng nested Navigator, §3.1) + 2 MINOR mới nhỏ (§3.1). |
| 4 | Trial 1 ngày | ⚠️ PASS-with-caveat | Không đổi — MJ9 residual (clock-forward trước lần mở app đầu tiên) vẫn là giới hạn được chấp nhận, không fix được bằng pure Dart. |
| 5 | VIP code, Ed25519, no server | ⚠️ PASS-with-caveat | **1 MINOR mới** (chữ ký sai độ dài làm crash cả vòng lặp rotation-key thay vì chỉ bỏ qua 1 key, §3.2) — fail-safe (từ chối key), không phải lỗ hổng giả mạo. |
| 6 | Consent mọi vùng (UMP/TCF, CCPA, ATT, COPPA) | ✅ PASS | Không tìm thấy gì mới; 1 doc nit (§3.3). |
| 7 | Tuân thủ chính sách AdMob/AppLovin | ⚠️ PASS-with-caveat | Không đổi — caveat duy nhất vẫn là BLOCKER key rotation (§4), risk-accepted, không phải finding source mới. |

## 3. Findings mới (theo từng vùng brief yêu cầu soi kỹ)

### 3.1 Adapter dispose/teardown race, App Open stacking, banner leak

**MAJOR mới — App Open có thể stack trên `showModalBottomSheet` ở app dùng
nested Navigator.** `AdScreenRouteLogger`
(`lib/src/core/ad_route_observer.dart:61-100`) chỉ thấy route được push lên
Navigator mà nó đăng ký (theo README: đăng ký 1 lần trên root
`MaterialApp.navigatorObservers`). `showDialog`/`showGeneralDialog` mặc định
`useRootNavigator: true` nên luôn rơi đúng Navigator được quan sát —
`isDialogOnTop` hoạt động đúng cho dialog. Nhưng **`showModalBottomSheet` mặc
định `useRootNavigator: false`** — nó push `ModalBottomSheetRoute` (một
`PopupRoute` thật) lên Navigator *gần nhất* với `context` gọi hàm, không phải
root. App dùng pattern bottom-nav-bar + `IndexedStack`/`Navigator` riêng mỗi
tab, hoặc `go_router` `ShellRoute`, gọi `showModalBottomSheet(context: ...)`
từ trong 1 tab mà không truyền `useRootNavigator: true` → route đó push lên
Navigator không có `observers` → `_popupDepth` không tăng → `isDialogOnTop`
vẫn `false`. Nếu app bị background rồi resume trong lúc sheet đang mở,
`showAppOpenAdOnResume()` (`ad_manager.dart:5938`, gate tại `:1476`) đọc
`isDialogOnTop == false` và hiển thị App Open đè lên sheet — đúng hành vi mà
cơ chế này tồn tại để chặn (theo doc-comment chính nó,
`ad_route_observer.dart:18-22`). README/example không có dòng nào cảnh báo
tích hợp phải đăng ký `AdScreenRouteLogger` trên Navigator lồng hoặc ép
`useRootNavigator: true` cho bottom sheet. **Cả `audit_codex_round28.md` và
`audit_agy_round28.md` đều kết luận "không tìm thấy path bypass App Open
stacking" — cả hai chỉ verify path dialog chuẩn, không xét asymmetry
`useRootNavigator` giữa `showDialog` và `showModalBottomSheet`.** Đây là
finding thật sự mới, chưa reviewer nào trong 3 bên bắt được.

**MINOR mới — cửa sổ chuyển tiếp khi dialog vừa pop.** `didPop()`/
`didRemove()` (`ad_route_observer.dart:71-89`) giảm `_popupDepth` ngay khi
`Navigator.pop()` được gọi, không đợi animation exit xong.
`showAppOpenAdOnResume()` chạy sau 1 `await`
(`_recheckConsentOnResume().timeout(...)`) nên có cửa sổ hẹp (<300ms) nơi
`isDialogOnTop` đã `false` trong khi dialog vừa pop còn đang fade-out trên
màn hình. Không phải data race thật (Dart đơn luồng), chỉ là mismatch trạng
thái hiển thị — cosmetic, không chặn.

**MINOR mới (debug-only) — `_selfCheckLoad` leak `StreamSubscription`.**
`ad_manager.dart:803-823` — `sub.cancel()` nằm sau `await load()` không có
`try/finally`. Nếu `load()` (được gọi qua `loadInterstitial`/
`loadRewardedAd`/`loadAppOpenAd`) throw, subscription trên `events` stream
broadcast không được huỷ, leak trong suốt vòng đời `AdManager`. Đường gọi
duy nhất là doctor/self-check API (`runIntegrationSelfCheck` hoặc tương tự),
không phải runtime production — severity thấp nhưng là leak thật, khớp
`BUG-6` trong `PROPOSALS-claude-2026-08-31.md` (vẫn chưa fix, khác các claim
khác trong file đó đã lỗi thời).

**Xác nhận KHÔNG phải bug (đối chiếu `PROPOSALS-claude-2026-08-31.md`):**
`BUG-3` (pickProviderCohort collapses A/B split) đã fix ở round-27 backlog B1
(`ad_manager.dart:390-427`, fallback cached random id thay vì `''`). `BUG-1/
2/5` (reinit-without-destroy guard gaps) đã fix — `_resetGuardState()` clear
timer, `installAdCrashGuard()` có idempotency guard, `AppLovinAdapter.dispose()`
null `eventSink`, AdMob banner/mrec/native có `identical(_xSlotsByKey[key],
slot)` guard. "Click-callback race" — không tìm thấy `Completer` pattern nào
trong `ad_manager.dart`/adapters, pattern nulled-before-fire dùng nhất quán.
`BUG-4` (`_disposedNativeKeys` unbounded) đã fix — `LinkedHashSet` cap 200,
FIFO eviction. **Bài học: file roadmap tự đề xuất hôm trước đã lỗi thời so
với source hiện tại ở phần lớn claim — không nên trust theo mặt chữ.**

Banner RouteAware (`banner_ad_widget.dart:138-155,251-263`) — verify độc lập,
xác nhận sạch: subscribe/unsubscribe đúng cặp mọi path kể cả route đổi giữa
chừng, `dispose()` luôn unsubscribe. `_retryRefillAds`/VIP resume — verify
độc lập, xác nhận sạch: đọc `_isVipMember` live mỗi lần gọi, timer tự chạy
độc lập app-lifecycle, không có kịch bản kẹt refill vĩnh viễn sau khi VIP hết
hạn lúc app ở background.

### 3.2 VIP ledger concurrency + Ed25519

Không có race read-modify-write: `addVip` (`vip_manager.dart:1058-1152`) mutate
`_entries` hoàn toàn đồng bộ, `await` đầu tiên (`_save()`) nằm SAU mutation —
mô hình run-to-suspension đơn luồng của Dart đảm bảo lệnh gọi thứ 2 chỉ bắt
đầu sau khi lệnh 1 mutate xong. Verify chéo `AdPreferences.addRedeemedVipKeyId`
qua chính source `shared_preferences` 2.5.5 — `_setValue` ghi cache đồng bộ
trước khi trả Future, nên read-modify-write coi như atomic per-isolate.
`maxVipStackDuration` clamp verify đúng ở cả 2 nhánh (stack + single), không
off-by-one, không bypass được bằng redeem dồn dập. Replay/forgery và clock
manipulation (MJ9) — không đổi so với round 26/27, đã biết và chấp nhận
(Android không có backstop chống reinstall, chỉ dựa Auto Backup — theo thiết
kế, ghi trong README "Known limitations").

**MINOR mới — thiếu length-check cho signature bytes trước khi verify.**
`signed_vip_key.dart:182-189` gọi thẳng `_ed25519.verify(...)` không check độ
dài `sig` trước. Nếu `sig.length != 64`, `cryptography` package's
`Ed25519.checkSignatureLength` throw `StateError` (không phải exception được
catch cục bộ tại điểm này) → phá luôn vòng lặp thử các rotation key khác thay
vì chỉ bỏ qua key hỏng đó (đúng ý đồ ghi trong comment `:164-166`). Vẫn
fail-safe (`redeemSignedKey` có catch-all bên ngoài,
`vip_manager.dart:1349-1352`, nên lỗi luôn dẫn tới "invalid", không bao giờ
tới "valid") — đây là gap về robustness/UX (một key hỏng chặn thử các key
rotation khác), không phải lỗ hổng giả mạo. Chưa từng được ghi nhận ở round
nào trước.

### 3.3 Consent/UMP edge case

Không tìm thấy gì mới. Verify lại 5 câu hỏi brief yêu cầu — network failure
tại `requestConsentInfoUpdate` fail-closed đúng (không bao giờ fail open sang
personalized ads); debug-geography chỉ construct `ConsentDebugSettings` khi
`kDebugMode`, không leak vào release build; ATT-trước-UMP chỉ warn (chủ ý,
không block); COPPA/AppLovin asymmetry code khớp doc mới thêm (Step 8.4,
commit `6784858`) — và thực ra gap "install mới chưa có consent" mà doc tự
nhận là "known gap" **đã có thể đóng ngay hôm nay** bằng cách gọi
`setConsent(isAgeRestrictedUser: true)` trước `initialize()` (được buffer vào
`_pendingConsentSettings`, `ad_manager.dart:2688-2703`, "B2 fix") — đây là
1 doc nit nên sửa câu chữ Step 8.4, không phải defect code. Staleness/
revocation giữa session — `_recheckConsentOnResume` re-check mỗi lần
foreground, không có gap.

## 4. BLOCKER round 26/27 — key rotation

**Không thể resolve từ source.** Việc key AppLovin + 8 ad-unit ID từng commit
vào lịch sử git chỉ khắc phục được bằng hành động ngoài source (rotate trên
dashboard AppLovin) — audit source không verify được việc này đã làm hay
chưa. Theo ghi nhận round 27, user đã 2 lần xác nhận chấp nhận rủi ro tạm
thời (repo còn private) — **theo đúng chỉ dẫn round 27, không hỏi lại vấn đề
này trong round audit này**, chỉ nêu như điều kiện còn treo (risk-accepted).

## 5. Đồng bộ pub.dev

Verify qua WebFetch (có network access): **`applovin_admob_sdk` trên pub.dev
đang ở version 2.9.6, khớp chính xác `pubspec.yaml` HEAD.** Changelog top
entry trên pub.dev khớp nội dung `CHANGELOG.md` local (VIP ledger race fix,
AdMob disposal-guard fix, RewardedInterstitial example coverage, main.dart
merge). README trên pub.dev liệt kê đủ 7 ad surface + VIP/trial Ed25519 +
GDPR/COPPA/CCPA/ATT + safety caps + SSV, khớp local. **Không có discrepancy.**

## 6. Đối chiếu với `codex`/`agy` round 28

Cả 3 reviewer độc lập đồng thuận: không BLOCKER/MAJOR regression mới trong 2
commit kể từ round 27, 1482/1482 test pass, không đổi verdict 7 yêu cầu so
với round 27 ngoại trừ các finding nhỏ mỗi bên tự đào được. `codex` (8.2/10)
và `agy` đều kết luận "không tìm thấy path bypass App Open stacking" — cả
hai verify path dialog chuẩn (`isDialogOnTop`, ref-count UMP form, buffer
splash) nhưng không xét riêng asymmetry `useRootNavigator` giữa `showDialog`
và `showModalBottomSheet` mà tôi tìm thấy ở §3.1 — đây là điểm khác biệt thật
sự giữa 3 báo cáo, không phải mâu thuẫn (2 bên kia không sai, chỉ chưa xét
đúng góc này). Cả 2 bên cũng xác nhận VIP concurrency sạch và trial clock
MJ9 residual không đổi, khớp kết luận của tôi.

## 7. Verdict cuối

**Ready for production use in a real consuming app: YES WITH CONDITIONS.**

**Điểm: 8/10.**

Điều kiện còn treo:
1. Rotate AppLovin key + 8 ad-unit ID trên dashboard trước khi mở repo access
   ra ngoài/public — risk-accepted, không hỏi lại (xem §4).
2. **Mới, khuyến nghị fix trước khi ship app dùng bottom-nav/nested Navigator
   (go_router ShellRoute, IndexedStack per-tab):** ép `useRootNavigator: true`
   cho mọi `showModalBottomSheet` gọi trong context có thể bị App Open đè lên,
   hoặc đăng ký `AdScreenRouteLogger` thêm trên Navigator lồng — nếu không,
   App Open có thể stack trên bottom sheet đúng kịch bản policy này được
   dựng ra để chặn (§3.1, MAJOR). Không chặn ship nếu consuming app hiện tại
   không dùng bottom sheet + nested Navigator.
3. Nhỏ, không chặn: `_selfCheckLoad` subscription leak (debug-only, §3.1),
   Ed25519 sig-length uncaught StateError phá vòng lặp rotation-key thay vì
   skip 1 key hỏng (fail-safe, không phải lỗ hổng, §3.2), Step 8.4 doc nit
   (§3.3).

So với round 27 (~7.8/10 trung bình 3 reviewer trước khi 2 MAJOR được fix
trong cùng round): điểm ổn định, không regression, 1 MAJOR mới thật sự (App
Open/bottom-sheet) đủ cụ thể và actionable để đáng trừ điểm nhưng không đủ
nghiêm trọng để đổi verdict — nó chỉ kích hoạt khi consuming app dùng pattern
Navigator lồng cụ thể, và fix là 1 dòng (`useRootNavigator: true`) ở phía
consuming app hoặc 1 doc note ở phía SDK.
