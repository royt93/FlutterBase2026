# Audit round 26 — verdict tổng hợp

**Ngày:** 2026-08-31
**Commit audit:** `1680214` (`docs(ad_sdk): update test documentation...`)
**Bối cảnh:** audit toàn diện theo yêu cầu — SDK + example, đối chiếu 7 yêu cầu sản phẩm
(dual-provider Android/iOS, online/offline, 4 loại ad đúng vòng đời không leak, trial 1
ngày, VIP by-code không backend, consent mọi quốc gia, policy compliance) và live pub.dev
listing, KHÔNG chỉ giới hạn ở theo dõi rotation-status của `doc/archive/AD.MD` (đã xoá ở
`0f503ba`, cùng phiên). Không đọc lại từ đầu baseline round 23–25 (đã ổn định, xem
`audit_round23_consolidated.md`) — chỉ xác nhận các fix/deliberate non-fix ở đó vẫn giữ
nguyên trong source hiện tại.

**Reviewer:** 3 CLI độc lập (`codex`, `agy`, `claude`) chạy song song + tôi (`claude`,
phiên chính) tự đọc trước và re-verify sau. Báo cáo gốc: `audit_codex_round26.md`,
`audit_agy_round26.md`, `audit_claude_round26.md`.

---

## 1. BLOCKER — AppLovin key/ad-unit ID vẫn còn trong git history, chưa rotate

Cả 3 reviewer độc lập đều bắt lại đúng 1 việc: **đây không phải finding mới** — nó là commit
`0f503ba` (đầu phiên này) đã tự ghi rõ trong message của chính nó: file `doc/archive/AD.MD`
(khởi nguồn tại `11d7421`) chứa 1 AppLovin SDK key thật + 8 MAX ad-unit ID, đã bị xoá khỏi
working tree nhưng **không** scrub history (chủ ý — rewrite history cần force-push +
owner sign-off). Chưa từng nằm trong artifact pub.dev (`.pubignore` loại `doc/`).

**Việc 3 reviewer xác nhận thêm, có giá trị thật:**
- Repo GitHub (`royt93/FlutterBase2026`) hiện là **PRIVATE** (tự kiểm bằng `gh repo view`)
  — giảm mức độ khẩn nhưng không loại trừ rủi ro (bất kỳ ai từng có quyền truy cập, hoặc
  nếu repo từng/sẽ chuyển public, vẫn đọc được).
- README dòng ~1893 nói "nothing real is committed to source" — đọc theo văn cảnh là
  tuyên bố về riêng `example/`, và tuyên bố đó **đúng** (đã tự grep toàn bộ lịch sử
  `example/` cho `ca-app-pub-` và `_kAppLovinSdkKey` — chỉ toàn ID test chính thức của
  Google `3940256099942544` và placeholder `YOUR_86_CHAR_SDK_KEY_FROM_APPLOVIN_DASHBOARD`,
  không có secret thật nào). Nhưng câu đó dễ bị đọc nhầm thành "toàn bộ repo chưa từng lộ
  secret", điều đó sai kể từ `11d7421`. Không tự sửa README (nằm ngoài scope audit-only,
  và cách đọc hẹp vẫn đúng nghĩa đen) — để chủ dự án quyết định có muốn thêm 1 dòng
  disclaimer trỏ tới sự cố `0f503ba` hay không.
- **Đã refute 1 claim:** `agy` báo thêm 1 điểm leak thứ hai ở
  `example/lib/splash_screen.dart` tại commit `86ca1b5`. Tự kiểm: **commit đó không tồn tại**
  trong repo (`git cat-file -t 86ca1b5` → lỗi), và mọi lần `_kAppLovinSdkKey`/`_kSdkKey`
  được định nghĩa trong lịch sử `example/` đều là placeholder hoặc
  `String.fromEnvironment(...)`, chưa bao giờ là literal thật. Đây là agent hallucination,
  không đưa vào verdict.

**Trạng thái đóng finding — vẫn treo, chưa đóng:** key + 8 ad-unit ID vẫn chưa được xác nhận
đã rotate trên AppLovin dashboard (nằm ngoài phạm vi audit source — cần xác nhận thủ công
với chủ tài khoản AppLovin). Đây là điều kiện chặn production duy nhất còn lại.

## 2. 6 MAJOR mới (Claude round 26), không có BLOCKER runtime mới

Không lật lại bất kỳ non-fix nào của baseline (MJ9, kQaTestDeviceHashes, native ads
RouteAware — vẫn y nguyên, đúng chủ ý). Đã tự spot-check 2 finding rủi ro cao nhất bằng
cách đọc lại source độc lập (không chỉ tin báo cáo) — cả hai đứng vững:

| # | File:line | Mô tả | Kịch bản lỗi | Severity |
|---|---|---|---|---|
| 1 | `lib/src/vip/_redeemed_key_ledger.dart` (`markRedeemed`) | Read-modify-write Keychain không lock | 2 lần redeem signed-key gần đồng thời → ghi đè lẫn nhau, 1 `kid` biến mất khỏi ledger durable (ledger chính SharedPreferences không bị race này) | MAJOR |
| 2 | `lib/src/adapters/admob_adapter.dart` (nhánh `onFailed` của 4 loại fullscreen ad) | Thiếu `_discardIfDisposed` guard đối xứng với `onLoaded`; `eventSink` không bị clear ở `dispose()` | `destroy()`/đổi provider giữa lúc 1 request load đang bay → GMA callback fail trễ trên adapter đã chết vẫn `_emit` ra ngoài | MAJOR |
| 3 | `lib/src/adapters/applovin_adapter.dart:801,837` | **Tự xác nhận bằng đọc lại source:** `dispose()` gọi `_bridge.setRewardedAdListener(null)` (dòng 801) **trước** khi resolve `_rewardedDone?.call(RewardResult.skipped)` (dòng 837) | User đã earn reward, native đã bắn event, event đó đang nằm trong platform-channel queue đúng lúc `destroy()` chạy → bị nuốt im lặng, host tưởng reward bị skip dù user đã xem xong — **mất tiền/mất reward thật, không phải giả thuyết hiếm** | MAJOR (sát BLOCKER) |
| 4 | `lib/src/core/ad_manager.dart:1624` (`_consentDialogScheduled`) | `Future.delayed` cho dialog consent nội bộ không lưu `Timer` để `cancel()` trong `destroy()` | `destroy()` rồi `initialize()` với `AdConfig` khác trong cửa sổ `consentDialogPostSplashDelay` → closure cũ fire với `AdConfig` CŨ đã capture, áp nhầm lên session mới | MAJOR |
| 5 | `lib/src/consent/*` / `applovin_adapter.dart:924-929` | Khoảng hở giữa `_persist()` (await) và `_applyToProviders()` — AppLovin consent thật chỉ áp ở bước sau, AdMob áp ngay | Trong khoảng hở, `canRequestAds` vẫn `true`, retry/refill có thể bắn 1 request AppLovin dùng consent cũ | MAJOR |
| 6 | `AdReadinessSplashController.dispose()` (ví dụ splash trong doc/README) | `dispose()` không set `_navigated = true` | Splash bị dispose thật (app bị kill/pop giữa splash) trong lúc đang chờ ad load → callback trễ vẫn gọi `_goReady()` → `onReady` (điều hướng host) chạy trên context đã deactivate → crash | MAJOR |

Đã tự verify #3 bằng đọc lại `applovin_adapter.dart` dòng 780-845, và #6 bằng đọc lại toàn
bộ `ad_readiness_splash_controller.dart` (164 dòng) — cả hai **CONFIRMED**, đúng thứ tự lệnh
như mô tả (`dispose()` không set `_navigated`; listener null hoá trước khi resolve reward).
Các finding còn lại (#1, #2, #4, #5) dựa trên báo cáo `claude` với grep evidence đi kèm
trong `audit_claude_round26.md` (agent đó tự đọc lại 2 lần trước khi báo, có trích code
nguyên văn) — coi là **PLAUSIBLE**, nên tự đọc lại thêm 1 lần nếu quyết định fix.

## 2b. Đối chiếu 7 yêu cầu sản phẩm (theo cả 3 reviewer + pass của tôi)

| # | Yêu cầu | Kết quả |
|---|---|---|
| 1 | AdMob + AppLovin, Android + iOS | ✅ PASS — 2 adapter tách biệt, cùng interface `AdProviderAdapter` |
| 2 | Có mạng / không mạng | ✅ PASS — connectivity watch + debounce 800ms, UMP fail-closed, backstop retry khi reconnect |
| 3 | 4 loại ad, đúng vòng đời, không leak | ⚠️ PASS với 2 race-window hẹp (#3, #6 ở trên) — không phải lỗi thiết kế, nhưng nên fix trước ship |
| 4 | Trial 1 ngày | ✅ PASS — mặc định 24h, MJ9 clock-rollback đã đóng (baseline) |
| 5 | VIP by-code, không backend | ✅ PASS — Ed25519 offline verify; #1 (ledger race) là lỗ hổng hẹp trên tính năng one-time-use, không phải lỗ hổng xác thực |
| 6 | Consent mọi quốc gia, cả 2 provider | ⚠️ PASS với 1 khoảng hở timing hẹp (#5) trên đường dialog mặc định — đường UMP đã được bảo vệ đầy đủ từ round 21/22 |
| 7 | Policy compliance | ⚠️ PASS về mặt code (12 lớp anti-fraud, no-stacking) — nhưng **chặn bởi BLOCKER** credential leak ở mục 1, đây là rủi ro account trực tiếp nằm ngoài code |

## 3. Việc tôi tự kiểm độc lập trước khi nhận báo cáo (không lặp lại của baseline)

- `AdManager._destroy()`/`_destroy()` teardown (`ad_manager.dart:4782-5136`): mọi
  listener/timer/controller được tạo (kể cả 3 listener sống suốt process ở constructor,
  chủ ý theo comment "T75") đều có đường hủy tương ứng. Sạch.
- Offline/connectivity: `_startConnectivityWatch`/`_stopConnectivityWatch` có backstop retry
  UMP khi mạng phục hồi (`ad_manager.dart:6643` — "C2 backstop"). Sạch, khớp baseline.
- VIP Android weak / iOS durable (README's "Known limitations"): xác nhận đúng bằng đọc
  `signed_vip_key.dart` + `_redeemed_key_ledger.dart` — iOS có Keychain-backed ledger,
  Android chỉ dựa SharedPreferences (wipe khi uninstall). Đúng như README công bố.

## Kết luận production

**Không approve production ở trạng thái hiện tại** — chặn bởi:

1. **BLOCKER treo:** rotate/revoke AppLovin key + 8 ad-unit ID đã lộ (xác nhận thủ công
   trên dashboard AppLovin, ngoài phạm vi source).
2. **Khuyến nghị fix trước khi ship** (không chặn cứng nhưng rủi ro tiền thật/crash thật):
   finding #3 (mất reward) và #6 (crash splash) ở trên — cả hai xảy ra trên đường dùng
   bình thường (thoát app giữa chừng), không cần điều kiện hiếm.
3. Finding #1, #2, #4, #5 — MAJOR nhưng cửa sổ hẹp, có thể xếp sau.

Nền tảng SDK (safety/caps, VIP Ed25519 offline, consent đa quốc gia, 4 loại ad
lifecycle/dispose ở `ad_manager.dart`) vẫn vững sau 25+ vòng audit trước — round này không
lật lại quyết định nền tảng nào, chỉ tìm thêm race-window hẹp ở biên teardown/consent.

`flutter analyze`: sạch. `flutter test`: 1.336/1.336 pass (theo cả 3 reviewer, không tự
chạy lại trong round này).
