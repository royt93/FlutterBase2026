# T116 — Tech debt: Contract-test chung cho AdProviderAdapter

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `core/ad_provider_adapter.dart`, test `admob_*`, `applovin_*`, bridge fakes, file mới `test/adapter_contract_test.dart`

## Vấn đề

Test 2 adapter nhiều nhưng parity chủ yếu được assert theo file riêng; lệch guard/callback/dispose thường chỉ lộ sau audit độc lập (đúng như T104/T105 vừa phát hiện). [đồng thuận 3 nguồn]

## Việc đã làm

- [x] `test/adapter_contract_test.dart` — 1 scenario matrix (`runContractSuite`) chạy qua `_Driver` abstraction (`_AdMobDriver`/`_AppLovinDriver`, mỗi driver bọc `FakeGmaBridge`/`FakeAppLovinBridge` sẵn có) cho cả 2 provider: consent epoch (`AdSlot.consentEpoch` bump + reset slot ready), show mutex (2 lần `showInterstitial` liên tiếp), dispose (`debugStateDisposed`), late callback sau dispose (không throw, bị silently drop), revenue (`AdRevenueEvent` qua `eventSink`), watchdog (App Open force-dismiss sau khi native không bao giờ confirm — dùng `fakeAsync`, AdMob qua `debugSimulateAppOpenShowAndArmWatchdog`, AppLovin qua `debugStartAppOpenWatchdog`, hard cap thực tế là tick thứ 19 = 95s do check chạy trên attempt trước-khi-tăng, không phải 90s tròn), N instances (`bannerSlot(key)` độc lập theo key)
- [x] Chỉ THÊM test — production code không đổi (chỉ thêm 1 field `paidCallback` capture vào `FakeGmaFullscreenAd` trong `test/admob_behavioral_test.dart`, cũng là test-only, để revenue test bắn được paid-event callback vốn trước đây bị fake bỏ qua)
- [x] Chạy trong CI cho cả 2 adapter — nằm trong `flutter test` mặc định (SDK primary gate), không cần job riêng
- [x] 14 test mới, full suite 1396→1410, không regression

## Ghi chú

Rủi ro thấp (chỉ thêm test). Nên làm TRƯỚC T114 (hợp nhất adapter) — làm lưới an toàn cho refactor đó — vẫn đúng, chưa làm T114.

## QA bổ sung (round-27 QA-hardening)

- [ ] Ticket này TỰ LÀ 1 test suite (test-only, không phải feature) — không cần integration test riêng cho chính nó.
