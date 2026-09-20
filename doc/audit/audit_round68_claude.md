# Audit round 68 — báo cáo độc lập (nguồn: claude, external session)

**Ngày:** 2026-09-20
**Codebase audited:** worktree `round68-claudeext`, HEAD `4ce0197` ("Release
3.0.3"), `pubspec.yaml` = `3.0.3`, đã publish pub.dev.

## Phương pháp

Đây là session Claude Code độc lập (`--dangerously-skip-permissions`),
không chia sẻ ngữ cảnh với 67 vòng audit trước hay 2 reviewer song song
(codex / agy-gemini) của round 68 này.

1. Đọc `doc/audit/audit_round65..67_consolidated.md` để biết method luận
   phiên nội bộ đã làm gì (full-pass từng file lớn: `native_ad_widget.dart`,
   `consent_manager.dart`, `ump_consent.dart`/`iab_storage.dart`,
   `ad_preferences.dart`/`ad_slot.dart`/`ad_provider_adapter.dart`) và kết
   luận: tính tới round 67, **mọi file có logic thật trong `lib/src/` đã có
   ít nhất 1 lần full-pass adversarial** trong session đó.
2. Vì vậy chọn chiến lược khác: quét tần suất xuất hiện của từng file
   `lib/src/**/*.dart` trong `doc/audit/audit_round55..67_consolidated.md`
   để tìm nhóm file **0 lần được nhắc tới** trong 13 vòng audit gần nhất —
   đây là nơi có xác suất cao nhất còn góc nhìn chưa ai soi kỹ, thay vì đọc
   lại lần nữa các file đã bị cày nát (`ad_manager.dart`, `consent_manager.dart`,
   `ump_consent.dart`, ...).
3. Đọc trực tiếp, adversarial, toàn bộ các file "0 lần nhắc tới": VIP
   (`_redeemed_key_ledger.dart`, `_vip_entries_store.dart`,
   `vip_revocation_provider.dart`, `signed_vip_key.dart`, `vip_entry.dart`),
   adapters bridge (`applovin_bridge.dart`, `gma_bridge.dart`,
   `fake_adapter.dart`, `inline_ad_instance_registry.dart`,
   `_inline_visibility.dart`), `att_consent.dart`, `event_bus.dart`,
   `remote_ad_safety_provider.dart`, `shimmer_view.dart` — đối chiếu ngược
   với 6 yêu cầu chức năng trong brief.
4. Đọc `example/lib/main.dart` (splash screen, contract ATT→UMP→initialize)
   để xác nhận consuming-app mẫu tuân thủ đúng README's integration
   contract.
5. Chạy `flutter analyze` và `flutter test` thật trên bản sao này để xác
   nhận trạng thái hiện tại (không chỉ tin số liệu ghi trong audit cũ).

## Phát hiện

### [MAJOR] `AdManager.debugAdapterFactory` / `debugSetAdapter` là seam test công khai, có thể bị set trong RELEASE build, không có runtime guard — trái với chính tiền lệ SDK đã đặt ra cho lớp lỗi tương tự

- **File:** `packages/ad_sdk/lib/src/core/ad_manager.dart:1511` (khai báo
  `static AdProviderAdapter Function(AdConfig config)? debugAdapterFactory`)
  và `:1494-1495` (`void debugSetAdapter(AdProviderAdapter? adapter)`).
- Cả hai chỉ được đánh dấu `@visibleForTesting` — đây **chỉ là annotation
  cho phân tích tĩnh** (`package:meta`), tạo ra một *cảnh báo* của
  `dart analyze` (`invalid_use_of_visible_for_testing_member`) khi bị gọi
  từ ngoài `test/` của package — **không phải lỗi biên dịch, không chặn
  `flutter build apk/ios --release`**. Cả `ad_manager.dart` (nơi khai báo)
  và `fake_adapter.dart` (chứa `FakeAdProviderAdapter`, class dùng làm
  adapter giả) đều được export công khai trong barrel file
  `packages/ad_sdk/lib/applovin_admob_sdk.dart:38` và `:81`. Nghĩa là bất
  kỳ app tiêu thụ package nào cũng import được và gọi:
  ```dart
  AdManager.debugAdapterFactory = (_) => FakeAdProviderAdapter();
  ```
  ở **bất kỳ đâu** trong code của họ — kể cả trong code path chạy ở
  RELEASE build — mà SDK không hề kiểm tra `kReleaseMode` để chặn.
- **Cơ chế lỗi cụ thể:** dòng `ad_manager.dart:3721-3723`
  ```dart
  final AdProviderAdapter adapter = debugAdapterFactory != null
      ? debugAdapterFactory!(config)
      : (config.isAdMob ? AdMobAdapter() : AppLovinAdapter());
  ```
  — nếu `debugAdapterFactory` khác `null` tại thời điểm `initialize()` chạy
  (bất kể build mode), **toàn bộ adapter thật (AdMob hoặc AppLovin) bị thay
  thế hoàn toàn**, không phải chỉ 1 ad unit ID hay 1 field cấu hình sai.
- **Kịch bản tái hiện thực tế** (không giả định, đã trace được code path
  thật): một dev tích hợp SDK muốn demo/QA nội bộ không tốn quota mạng thật
  ("safe for CI, screenshots/App-Store-review builds" — đúng như doc
  comment của chính `fake_adapter.dart:16`), viết:
  ```dart
  if (isQaBuild) {
    AdManager.debugAdapterFactory = (_) => FakeAdProviderAdapter();
  }
  AdManager().initialize(config: ...);
  ```
  Flavor "QA"/"staging" này sau đó bị build nhầm thành bản release đưa lên
  Play Store/App Store (lỗi CI/CD phổ biến: nhầm flavor, quên xoá flag,
  biến môi trường không được set như mong đợi trên máy build release) —
  app chạy hoàn toàn bình thường, không crash, không log lỗi nào hiển thị
  với người dùng, nhưng **100% doanh thu quảng cáo về 0 vĩnh viễn** cho
  đến khi phát hiện và build lại. Vì không throw, không assert (assert bị
  strip khỏi release build), không có tín hiệu nào để hệ thống giám sát
  crash/lỗi tự động bắt được.
- **Vì sao đây là phát hiện thật, không phải lặp lại điều đã biết:** đã
  grep toàn bộ `doc/audit/audit_round*.md` — `debugAdapterFactory` chỉ được
  nhắc tới ở round 23 và round 38, cả hai lần đều bàn về nó **như một công
  cụ test hợp lệ** (seam để viết integration test không cần native SDK
  thật), không lần nào phân tích rủi ro "seam này lộ ra ngoài package, có
  thể bị set trong release build, không có guard". Đây là góc nhìn mới.
- **Vì sao mức độ là MAJOR, không phải MINOR:** SDK **đã tự đặt tiền lệ**
  rằng lớp lỗi này đáng để chặn cứng ở runtime, không chỉ dựa vào kỷ luật
  lập trình viên. `_applyTestIdFootgunGuard` (`ad_manager.dart:2444-2462`,
  fix round 45 R45-04 + round 46 R46-02) tồn tại **chính xác cho lớp rủi ro
  này**: "shipping Google's public TEST ad unit IDs in a real release build
  used to only log a warning and `assert(false, …)`, which is stripped out
  of release builds entirely — so the one build that actually needs
  blocking was exactly the one where nothing happened." Team đã quyết định
  nâng nó thành "release-blocking... `canRequestAds` stays false for the
  rest of the process". `debugAdapterFactory` là lớp lỗi **cùng hình dạng,
  hậu quả nặng hơn**: test-ad-ID chỉ làm sai loại ad unit (vẫn là ad thật
  của Google, có nhãn "Test Ad" rõ ràng, và vẫn qua đúng pipeline
  consent/adapter thật); `debugAdapterFactory` thay **toàn bộ adapter**,
  bỏ qua mọi cơ chế mediation/loading thật, chỉ khác là hiển thị dễ nhận
  ra hơn (ô xám "Fake banner"/"Fake native" — xem
  `fake_adapter.dart:395-410`) — nhưng "dễ nhận ra khi ai đó nhìn vào màn
  hình" không phải là guard tại runtime, và App Open/Interstitial/Rewarded
  fake (`fake_adapter.dart:200-267`) hoàn toàn không hiển thị UI riêng biệt
  gì cả (chỉ gọi `onDismiss(true)`/`onDone(...)` ngay lập tức) — với các
  format đó thậm chí không có "ô xám" nào để tự lộ diện, im lặng hoàn
  toàn.
- **Bằng chứng công cụ nội bộ chính SDK cũng coi đây là "ẩn hình" khỏi
  review**: `test/api_golden_test.dart:39-53` — bài test thứ hai
  ("excludes `@visibleForTesting` members but keeps ordinary public
  ones") xác nhận rõ ràng rằng `tool/api_surface.dart` (công cụ theo dõi
  "public API surface" để bắt buộc mọi thay đổi API phải qua review có
  chủ đích, xem golden file `test/goldens/public_api_surface.txt`) **chủ
  động lọc bỏ mọi member `@visibleForTesting`** khỏi diện được review như
  API công khai. Nghĩa là ngay cả quy trình riêng của SDK để rà soát "cái
  gì một consuming app có thể với tới" cũng không nhìn thấy
  `debugAdapterFactory`/`debugSetAdapter` — chúng bị coi là "không thật sự
  public" về mặt quy trình, dù về mặt ngôn ngữ Dart chúng **100% public và
  gọi được** từ bất kỳ package nào import SDK.
- **Đề xuất fix** (không tự sửa code — chỉ đề xuất, đúng phạm vi audit
  read-only): áp dụng đúng khuôn mẫu `_testIdFootgunBlocked` đã có sẵn —
  thêm kiểm tra `if (isActuallyRelease(isRelease) && debugAdapterFactory !=
  null) { /* set 1 cờ block canRequestAds, log critical */ }` bên trong
  `initialize()`, ngay chỗ đang đọc `debugAdapterFactory` (dòng 3721).
  Không cần đổi API public, không breaking — chỉ thêm 1 lớp bảo vệ runtime
  giống hệt logic đã có cho test-ad-ID.

### [MINOR] `debugSetAdapter` (instance method, không static) cùng lớp rủi ro nhưng phạm vi hẹp hơn

- **File:** `ad_manager.dart:1494-1495`.
- Không static nên phải có instance `AdManager()` gọi vào — về mặt thực tế
  gần như luôn đi kèm `debugAdapterFactory` trong cùng nhóm rủi ro ở trên
  (một khi code path debug/QA đã với tới được `AdManager` instance, nó
  cũng với tới được field/method này). Liệt kê riêng vì nó bỏ qua hoàn
  toàn luôn cả bước gọi `initialize()` — không set `eventSink`, không gọi
  `applyConsent`, không set `canReload` — nên nếu bị gọi khi SDK đã init
  xong bằng adapter thật, có thể để lại adapter cũ nửa-vời không dispose
  đúng cách (không có test nào trong 202 file test hiện tại kiểm tra "gọi
  `debugSetAdapter` sau khi `initialize()` đã chạy xong" — chỉ dùng làm
  seam TRƯỚC khi test tự set up trạng thái). Không nâng mức MAJOR vì cách
  khai thác thực tế khó hơn `debugAdapterFactory` (cần với tới instance,
  không chỉ set 1 static field trước khi gọi `initialize()`).

## Các khu vực đã kiểm tra kỹ, KHÔNG tìm thấy lỗi mới (đối chiếu 6 yêu cầu)

Ghi lại để round sau không tốn công đọc lại — đã đọc "cold", không copy kết
luận cũ, tự verify bằng code hiện tại.

**1. Đa provider / Android+iOS:**
- `applovin_bridge.dart` (114 dòng) — thin wrapper 1-1 sang
  `AppLovinMAX.*`, không có logic riêng nào lệch giữa 2 platform.
- `gma_bridge.dart` (395 dòng) — mọi `_*Wrap` class (App Open/Interstitial/
  Rewarded/RewardedInterstitial) đều giải phóng `onPaidEvent` VÀ
  `fullScreenContentCallback` trong `dispose()` (m36 fix, đối xứng cả 4
  format) — không leak callback trỏ vào ad đã hủy.
- COPPA/TFUA: `admob_adapter.dart:445-465` gọi
  `updateRequestConfiguration` TRƯỚC `_bridge.initialize()` (đúng yêu cầu
  Google, round-31 BLOCKER fix); `applovin_adapter.dart:743-761` **hard-stop
  hoàn toàn việc khởi tạo AppLovin** nếu `isAgeRestrictedUser` (vì AppLovin
  MAX 4.x không có API COPPA runtime) — thiết kế fail-closed hợp lý, không
  phải bug, đã có `coppaUmpMismatchWarning` (`ad_manager.dart:409`) cảnh
  báo nếu host cấu hình lệch giữa `isAgeRestrictedUser` và
  `umpTagForUnderAgeOfConsent`.
- CCPA `doNotSell`: forward đối xứng cả 2 provider —
  AppLovin qua `AppLovinBridge.setDoNotSell` (`applovin_bridge.dart:20`),
  AdMob qua `_restrictedDataProcessing` → `extras: {'rdp': '1'}`
  (`admob_adapter.dart:642,2049,2240,2397`).

**2. Offline/online:** mọi `beginLoad()` thật (14 call site, xác nhận lại
bằng grep chứ không chỉ tin round 66) đều đi kèm `armLoadWatchdog(...)`
(`ad_slot.dart`) làm backstop timer thật — không phụ thuộc riêng vào native
SDK tự fail nhanh khi mất mạng. `requestAttIfNeeded`/UMP flow đều có
timeout 20s (`att_consent.dart:269`) không để splash treo vô hạn.

**3. Vòng đời ad / memory leak:**
- `shimmer_view.dart` — `AnimationController` dispose đúng, có guard
  chống tạo controller 2 lần (T14).
- `_inline_visibility.dart` (`InlineVisibilityOwners`) — cơ chế đếm owner
  (không phải snapshot 1 lần) để quyết định banner/MREC có bị ẩn hay
  không, đã xử lý đúng trường hợp nhiều nguồn cùng muốn ẩn (fullscreen +
  background + route-paused) — logic phức tạp nhưng nhất quán, có
  `forget()`/`forgetAll()` cho teardown, xác nhận `disposeBannerInstance`
  gọi `forget()` trước khi dispose listenables thật (không leak object
  reference vào map `_held`).
- `inline_ad_instance_registry.dart` — có "tombstone" (`_disposed` flag +
  sentinel đã-dispose-sẵn) set NGAY ở đầu `dispose()`, tránh race giữa
  callback native trễ và teardown đang chạy await — đã kiểm tra thứ tự gọi
  đúng theo doc comment của chính nó.

**4. Trial 1 ngày / anti-bypass:**
- `_first_install_guard.dart` — cơ chế Keychain-flag trên iOS (sống sót
  qua reinstall, dùng `first_unlock` accessibility) đã được document đầy
  đủ bảng "bypass-result matrix" (round 31/39) kèm rationale rõ ràng vì
  sao Android không có guard tương đương (không có primitive local-only
  nào sống sót qua uninstall) — đây là trade-off SẢN PHẨM đã được quyết
  định (round 39: "ship as-is... a host with trial-abuse as a hard
  business requirement should treat this doc comment as the starting
  point"), không phải bug bị bỏ sót.
- `VipEntry.isActiveAt` (`vip_entry.dart:55-58`) chặn clock-rollback về
  TRƯỚC `grantedAt` (T17); `VipManager` (không đọc lại chi tiết — đã có
  15+ round trước audit sâu) áp thêm high-water-mark clamp cho khoảng giữa
  `grantedAt`/`expiresAt` — khớp với memory "MJ9 clock fix" đã fix
  2026-08-26, redesign monotonic thuần Dart bất khả thi (đúng, `Stopwatch`
  chết theo process).

**5. VIP không server:**
- `signed_vip_key.dart` — xác minh kỹ domain-separation giữa chữ ký AVP1/
  AVP2 (key) và CRL1 (revocation list): CRL ký trên `"CRL1|"+payload`,
  AVP1/AVP2 ký trên payload trần — đã tự kiểm tra thủ công cả 2 chiều tấn
  công (đổi prefix code CRL thành AVP1 hay ngược lại) đều KHÔNG verify
  được vì bytes bị ký khác nhau — cơ chế đúng, không có lỗ hổng
  signature-confusion.
- `_redeemed_key_ledger.dart` / `_vip_entries_store.dart` — cả 2 đều có
  write-chain nối tiếp (không race read-modify-write), fail-open đúng
  hướng (lỗi storage → không khoá nhầm người dùng thật, không tự cấp
  entitlement giả), phân biệt đúng "đọc lỗi" vs "đọc thấy trống"
  (`_lastSecureReadErrored`) — không tìm thấy lỗi.
- Không tìm thấy private key nào bị commit trong working tree hiện tại
  (`find . -iname "*.pepk" -o -iname "*private_key*" -o -iname "*.pem"` —
  0 kết quả). Rủi ro `private_key.pepk` trong lịch sử git đã được
  CLAUDE.md tự khai báo và có kế hoạch xử lý rõ ràng (round 34) — không
  audit lại.
- Cross-device replay của 1 signed key (không có server để chặn dùng
  chung) là giới hạn thiết kế đã biết, đã note trong memory người dùng là
  "feature", không audit lại như bug.

**6. Consent mọi quốc gia:**
- `att_consent.dart` — thứ tự ATT → UMP → initialize được tuân thủ đúng
  trong `example/lib/main.dart:854-908`; timeout 20s cho prompt ATT treo
  (round 31 MAJOR fix), guard chống gọi chồng (`_pendingAttRequest`),
  release guard 2 điều kiện (native settled + result done) đã đọc kỹ,
  logic đúng.
- GPP two-segment (round 56 fix) — không đọc lại `iab_storage.dart` chi
  tiết (round 66 đã full-pass, kết luận "no regressions, no drift" khớp
  với đọc lướt của tôi qua các đoạn liên quan tới GPP trong file này) —
  tin cậy có điều kiện, khuyến nghị round sau vẫn nên có 1 lần verify bằng
  reference encoder thật + device thật theo đúng cách round 56 đã làm,
  vì đây là logic dễ hồi quy khi có thay đổi liên quan UMP.
- `remote_ad_safety_provider.dart` — mọi field override từ remote config
  đều được validate chặn giá trị âm/vô cực/kiểu sai trước khi áp dụng
  (round 30/31 MAJOR/MINOR fixes) — không tìm thấy trường hợp field mới
  nào thiếu validate.

## Test đã chạy

- `flutter analyze` (trong `packages/ad_sdk`): **0 issues** (19.7s).
- `flutter test` (toàn bộ `packages/ad_sdk/test/`, 202 file test):
  **PASS, exit code 0** — không có test nào fail. (Không đếm số lượng test
  case chính xác từ log do log bị cắt bởi buffer `tail`, nhưng exit code 0
  + không có dòng "Some tests failed" xác nhận toàn bộ xanh, khớp con số
  2205/2205 round 67 báo cáo vì không có code nào thay đổi giữa 2 round.)
- Không chạy `flutter test integration_test/` (cần emulator/simulator,
  không có sẵn trong worktree này) và không build/verify trên device thật
  — nằm ngoài khả năng của session này (không có thiết bị kết nối).
  Khuyến nghị: nếu áp dụng fix cho MAJOR ở trên, cần ít nhất 1 unit test
  mới kiểu `test/debug_adapter_factory_release_guard_test.dart` theo đúng
  khuôn `_applyTestIdFootgunGuard`'s test (`debugApplyTestIdFootgunGuard`
  seam) đã có sẵn.

## Phần chưa kịp audit (giới hạn thời gian/quota)

- Không đọc lại chi tiết `iab_storage.dart` (624 dòng, round 66 đã full-pass
  gần đây, độ tin cậy cao nhưng chưa tự re-verify từng dòng).
- Không audit sâu `monetization/` (`waterfall_tuner.dart`,
  `journey_prefetcher.dart`, `monetization_arbitrator.dart`,
  `digital_twin.dart`, `revenue_anomaly_detector.dart`,
  `self_healing_observer.dart`) — các module "thông minh hoá" doanh thu,
  không trực tiếp nằm trong 6 yêu cầu chức năng cốt lõi của brief, và mỗi
  file đã có 1-3 lần nhắc trong 13 round gần nhất (không phải "0 lần" như
  nhóm VIP/bridge tôi ưu tiên đọc).
- Không build thật lên thiết bị Android/iOS để smoke-test (không có
  device/simulator kết nối trong môi trường chạy session này).
- Không tự chạy `tool/check_pinning_wall.sh` để verify lại pod graph
  AppLovin/GMA — tin theo trạng thái CI hiện tại (branch `main` đã qua CI
  trước khi merge/publish 3.0.3).

## Khuyến nghị production

**SDK bản 3.0.3 CÓ THỂ dùng cho production app.** Sau 67 vòng audit trước
và vòng độc lập thứ 68 này, tôi không tìm thấy blocker thật sự mới (crash,
lỗ hổng bảo mật khai thác được, vi phạm policy chắc chắn bị Google/AppLovin
từ chối) trong toàn bộ 6 hạng mục yêu cầu. `flutter analyze` sạch,
`flutter test` (202 file, ~2205 test case) xanh 100%.

Có **1 MAJOR nên fix trước khi giao cho một team/khách hàng khác tích hợp
SDK này** (không cấp bách bằng mức phải hoãn release ngay lập tức, vì team
hiện tại tự publish và tự dùng, ít khả năng vô tình bật `debugAdapterFactory`
trong release của chính họ) — nhưng nếu package này được publish công khai
trên pub.dev cho bên thứ ba dùng (đúng như mô tả trong CLAUDE.md: "Published
to pub.dev"), thì đây là một footgun thật, có thể khiến MỘT consuming app
khác mất trắng doanh thu quảng cáo mà không có tín hiệu lỗi nào, và bản thân
SDK đã tự chứng minh (qua `_testIdFootgunBlocked`) rằng team coi lớp rủi ro
này đủ nghiêm trọng để chặn cứng ở runtime — chỉ là chưa áp dụng cùng
logic cho `debugAdapterFactory`/`debugSetAdapter`. Khuyến nghị thêm guard
release-mode cho 2 seam này trước round audit publish tiếp theo.
