# T264 — Cơ Chế Nạp Trước Thông Minh Dựa Trên Mức Độ Tương Tác Của Người Dùng (Smart Preload Watermarking)

- **Loại:** Feature / Monetization Optimization
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (2026-10-23; code, unit/widget tests, TECNO integration pass; full SDK suite 2,781/2,781; chưa đo được tác động Show Rate/eCPM trên dashboard)

## Bối cảnh & Vấn đề

Hiện tại, ngay khi ứng dụng khởi chạy xong splash, SDK tự động gửi request nạp trước (preload) cho Interstitial và Rewarded ad:
- Thống kê thị trường cho thấy khoảng 15-25% người dùng mở app nhầm hoặc chỉ kiểm tra nhanh rồi đóng app trong vòng dưới 10 giây (Bounce users).
- Các quảng cáo nạp trước cho nhóm người dùng này không bao giờ được hiển thị, dẫn đến:
  1. Lãng phí băng thông mạng của người dùng.
  2. Tăng số lượng ad request mà không có impression, làm tụt tỷ lệ hiển thị (Show Rate) và khiến thuật toán của Google AdMob / AppLovin hạ điểm chất lượng inventory (eCPM bị giảm sút).

## Đề xuất giải pháp

1. Thêm cơ chế **Engagement-Gated Preload**:
   - Chỉ nạp trước App Open và Banner ngay lập tức.
   - Trì hoãn việc nạp trước Interstitial / Rewarded cho đến khi người dùng thỏa mãn một trong các điều kiện tương tác:
     - Đã ở trong app liên tục >15 giây.
     - Hoặc đã thực hiện ít nhất 2 lần chuyển màn hình (route navigation).
     - Hoặc host app chủ động gọi `AdManager().markUserEngaged()`.
2. Có cờ cấu hình `AdConfig.smartPreloadEnabled` (mặc định `true`, có thể tắt để nạp ngay như cũ).

## Acceptance Criteria

- [x] Preload tự động Interstitial / Rewarded / RewardedInterstitial bị hoãn cho tới khi có engagement; App Open và banner/MREC không đổi. Test và log TECNO xác nhận slot `idle` sau khi App Open `ready`.
- [x] Đủ 15s foreground liên tục, 2 navigation sau init, hoặc `markUserEngaged()` thì tải đúng một lần (unit + widget với `Navigator` thật + TECNO).
- [ ] Nâng Show Rate / bảo vệ eCPM trên dashboard sàn: **chưa kiểm chứng**. Test chỉ chứng minh số request fullscreen trước engagement giảm về 0 trong harness; hiệu quả doanh thu cần đo production/A-B riêng.
- [x] `flutter analyze` sạch (SDK + example); full suite 2,781/2,781; `release_readiness_gate.sh all` pass (size 2048 KB, trần không đổi).

## Quyết định đã chốt (owner, 2026-10-23)

- Gate áp cho preload/refill **tự động**: sau App Open settle, VIP hết hạn, retry scan 5 phút, reconnect, `AdScreenState.initState()` và `JourneyPrefetcher.notifySignal` (chỉ format fullscreen; App Open/banner không đổi). `loadInterstitial()` / `loadRewardedAd()` do host gọi trực tiếp, `showRewardedAd(bypassVipGuard)` on-demand và reload sau khi show không bị chặn. Ban đầu chỉ chốt đường tự động trong SDK; sau audit độc lập, owner chọn gate **cả AdScreen và JourneyPrefetcher** vì nếu không, host theo hợp đồng chuẩn (home extends AdScreen) tải Interstitial ngay khi mở home và gate mất tác dụng.
- Gate cả RewardedInterstitial cùng hai format nêu trong task.
- 15s tính **foreground liên tục**: pause hủy timer, resume sau pause đếm lại từ 0; `inactive→resumed` không có pause **không** reset đồng hồ; init xong khi app đang ở nền thì chỉ bắt đầu đếm khi resume. 2 navigation tính từ lúc `initialize()` (baseline), chỉ tính page route: dialog/bottom sheet (kể cả `AdLoadingDialog` của SDK) không tính. Nguồn đếm là `AdScreenRouteLogger` nên host phải đăng ký observer này.

## Thực thi và bằng chứng

- Code: `AdConfig.smartPreloadEnabled` (mặc định `true`); `AdManager.markUserEngaged()`; `AdScreenRouteLogger.navigationEventsNotifier`; `AdManager.deferAutoPreload()` (`@internal`, dùng chung cho AdScreen và JourneyPrefetcher). Gate tại `_onAppOpenStateChange`, `_onVipActiveChanged`, `_retryRefillAds` (bao cả reconnect), `AdScreenState.initState`, `JourneyPrefetcher.notifySignal`. Reset trong `_disposeAdapter` (`destroy()` đi qua đây).
- Test: `test/t264_smart_preload_test.dart` (28 ca: mặc định, hoãn, release 1 lần, trước/sau App Open settle, 1 vs 2 navigation thật, dialog không tính, navigation trước init (1 trước + 1 sau init chỉ tính 1), 15s vs 14s, pause reset, `inactive→resumed` không reset, init khi đang ở nền, retry, VIP, host load, AdScreen hoãn/sau engagement/opt-out, JourneyPrefetcher hoãn và sau engagement, opt-out, destroy, re-init). Mutation check: bỏ từng điểm (open-state gate, retry gate, VIP gate, pause-cancel, reset ở `_disposeAdapter`, `_navBase`, lọc popup, điều kiện `prev==paused`, arm-khi-ở-nền) đều làm test tương ứng đỏ; reset thừa trong `_resetGuardState` bị loại vì không test nào cần.
- Audit độc lập (agent riêng, đọc diff): 2 MAJOR đã sửa (dialog của SDK tự đếm thành 2 navigation làm gate mở ngay ở splash; AdScreen/JourneyPrefetcher tải Interstitial không qua gate), 2 MINOR đã sửa (timer chạy khi init xong lúc ở nền; `inactive→resumed` reset đồng hồ), 1 MINOR đã sửa (test navigation-trước-init vacuous, probe debug bỏ quên). Chưa sửa/ghi nhận: `AdScreenRouteLogger.resetState()` về 0 thấp hơn baseline chỉ xảy ra khi test/crash recovery vì `destroy()` không gọi nó; khi VIP đang active mà engagement đạt thì 3 `loadX()` phát 3 `AdSkipEvent('vip')` (nhiễu log, không sai hành vi).
- Integration TECNO KJ7 Android 14, Google test ads: `example/integration_test/t264_smart_preload_test.dart` 4/4 pass (hoãn rồi release sau `markUserEngaged()`; host `loadInterstitial()` không bị chặn và Rewarded vẫn `idle`; màn `AdScreen` mở trước engagement không preload rồi preload sau `markUserEngaged()`; opt-out nạp ngay). Log `/tmp/t264_tecno2.log` (local).
- Test cũ phải opt-out `smartPreloadEnabled: false` vì chúng kiểm tra refill/reconnect/VIP chứ không phải engagement: `connectivity_*`, `ad_manager_connectivity_transition`, `fast_refill_rewarded_interstitial`, `tcf_personalisation_consent`, `r73_vip_expiry_recheck_on_resume`, retry timer trong `ad_manager_core_test`.
- Giới hạn size gate: lib ở đúng 2048 KB; thêm code phải bù bằng cách rút gọn comment. Đã rút gọn `revenue_panel.dart` (-1 block) và `ad_route_observer.dart` (doc comment `showAdSafeModalBottomSheet`); không đổi ngưỡng.

## Re-audit và regression verification (2026-10-23)

- Audit chuỗi 7 commit phát hiện 2 lỗi T264 đã xác minh bằng test đỏ: (1) resume sau chuỗi Android `paused→hidden→inactive→resumed` không arm lại timer vì code chỉ nhận `prev==paused`; (2) notifier chỉ báo page route nhưng baseline/phép so sánh dùng `navigationEventsObserved` gồm popup, nên dialog mở/đóng + 1 page có thể mở gate.
- Sửa lifecycle: paused/hidden hủy timer; resumed chỉ arm lại khi engagement gate đã được khởi tạo và timer đang null. `inactive→resumed` không có background giữ nguyên timer. Sửa navigation: baseline và phép so sánh cùng dùng `navigationEventsNotifier.value` (page-only), không đổi bộ đếm self-check T98.
- T264 focused **28/28 pass**; full SDK **2,781/2,781 pass**; analyzer SDK + example sạch; release gates `all` pass (2048 KB). Test thêm/phát huy: chuỗi Android đầy đủ, hidden không qua paused, popup trước init, popup cycle + 1 page sau init. Mutation M12/M14/M15 (baseline gồm popup, hidden không cancel, compare gồm popup) đều đỏ đúng test; mutation bỏ resume re-arm cũng đỏ. Code đã khôi phục sau mutation.
- Integration TECNO mặc định **4 pass, 1 skip** (host-driven case opt-in), log `/tmp/t264_fix_tecno_default.log`. Host-driven case với `--dart-define=T264_HOST_LIFECYCLE=true --plain-name 'host-driven resume'`: host đợi `T264_HOST background_ready`, gửi Home; đợi `T264_HOST paused`, rồi relaunch activity. Log `/tmp/t264_host_lifecycle2.log` xác nhận real OS paused/hidden/inactive/resumed, vẫn idle ở giây 14 sau resume, tự release secondary preload sau mốc 15s; **1/1 pass**. Không gọi `markUserEngaged()` hay API `@internal` trong ca này.
- Kiểm chứng tương thích test cũ với T264 mặc định `true`: `interstitial_ad_test.dart` và `rewarded_ad_test.dart` trên TECNO/AdMob test IDs đều **1/1 pass**, mỗi test native show+dismiss hai chu kỳ; rewarded cả hai có `earned=true`. Logs `/tmp/t264_interstitial_verified.log`, `/tmp/t264_rewarded_verified.log`. Lượt interstitial đầu hết thời gian chờ đóng ở chu kỳ 2; rerun với UIAutomator quan sát và tap đúng close control thì pass. Không chỉnh test/example config để tắt gate.
- Integration mở rộng trên TECNO/AdMob test IDs sau hai fix: `round37_dialog_gating_test.dart`, `t139_journey_prefetcher_auto_route_signal_test.dart`, `journey_prefetcher_test.dart` đều **1/1 pass**. Log local `/tmp/t264_round37_dialog_gating_test.log`, `/tmp/t264_t139_journey_prefetcher_auto_route_signal_test.log`, `/tmp/t264_journey_prefetcher_test.log`. Các test này bổ sung kiểm tra dialog/route/Journey, không thay thế test T264 trực tiếp.
- Ca bổ sung: init hoàn tất khi `hidden` phải chờ resume mới đếm 15s. Test/mutation M16 xác nhận việc bỏ kiểm tra hidden ở init làm test đỏ. Full SDK sau ca này **2,781/2,781 pass**, focused T264 **28/28 pass**, analyzer SDK/example và gate `all` sạch tại 2048 KB.
- Independent follow-up review: các reviewer ban đầu bị isolation chặn checkout gốc nên không có kết luận. Một reviewer khác đọc các đoạn source hiện tại do parent cung cấp (không chạy test, không đọc toàn checkout), không thấy blocker trong các đoạn lifecycle/counter/reset; nêu thiếu assertion App Open ready trong host-driven test. Assertion đã bổ sung và test TECNO Home/relaunch chạy lại **1/1 pass**, log `/tmp/t264_host_lifecycle3.log`. Secondary non-idle chỉ chứng minh request bắt đầu, không khẳng định ad đã ready trong ca lifecycle này.
- Mở rộng integration TECNO 2026-10-24: `t266_reconnect_jitter_stagger_test.dart` pass sau khi fixture gọi `markUserEngaged()` (T266 đo spacing sau engagement, không phải gate T264); `consent_gate_recovery_test.dart` pass sau khi fixture báo engagement trước khi assert secondary refill; `r173_debug_overlay_banner_row_test.dart`, `round37_dialog_gating_test.dart`, `t139_journey_prefetcher_auto_route_signal_test.dart`, `journey_prefetcher_test.dart`, `r23_banner_revive_on_vip_expiry_test.dart`, `vip_fast_refill_demo_test.dart` đều pass. `t192_debug_overlay_navigation_crash_test.dart` ban đầu đỏ vì first-install VIP grace làm load bị VIP-gated; fixture nay revoke grace + `markUserEngaged()` trước khi kiểm tra crash, pass, vẫn xác nhận slot loading. `interstitial_ad_test.dart` / `rewarded_ad_test.dart` cũng pass hai chu kỳ show/dismiss test ad. Các fixture thay đổi này chỉ tách mục tiêu test khỏi gate T264; SDK behavior không đổi.
- Các kết quả trên chưa là toàn bộ example integration suite, chưa là Pixel/iOS/AppLovin. Chưa push follow-up.

## Rủi ro / việc theo dõi

- Mặc định `true` đổi hành vi: Interstitial/Rewarded hiện ngay trong vài giây đầu có thể chưa `ready`. CHANGELOG và README đã ghi cách xử lý (`markUserEngaged()` sớm hơn hoặc `smartPreloadEnabled: false`).
- Timer 15s dùng hằng nội bộ, chưa cấu hình được; thêm field khi có nhu cầu.
- Chưa có Pixel 7 Pro / iOS; chưa kiểm chứng trên AppLovin. Chưa chạy lại cả bộ `example/integration_test` với mặc định mới: các test mong slot Interstitial/Rewarded `ready` sớm có thể cần `smartPreloadEnabled: false` hoặc `markUserEngaged()` (suy đoán, chưa kiểm chứng).
- Host không đăng ký `AdScreenRouteLogger` (ví dụ game một màn) chỉ còn timer 15s hoặc `markUserEngaged()`; nút xem Rewarded gắn với `rewardedSlot.isReady` sẽ tắt trong 15s đầu (suy đoán, chưa kiểm chứng).
- Diff có rút gọn comment ở `ad_route_observer.dart` và `revenue_panel.dart` chỉ để giữ size gate; không đổi hành vi.

## Kế hoạch kiểm thử

- **Unit test:** Giả lập dòng thời gian tương tác, kiểm tra thời điểm kích hoạt request nạp quảng cáo.
- **Widget test:** Tương tác chuyển màn hình và xác nhận ad slot chuyển sang trạng thái `loading`.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T264 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/ad_manager.dart, lib/src/state/ad_slot.dart.
2. Viết test trước để kiểm tra cổng kích hoạt nạp trước thông minh (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
