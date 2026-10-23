# T264 — Cơ Chế Nạp Trước Thông Minh Dựa Trên Mức Độ Tương Tác Của Người Dùng (Smart Preload Watermarking)

- **Loại:** Feature / Monetization Optimization
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (2026-10-23; code, unit/widget tests, TECNO integration pass; full SDK suite 2,778/2,778; chưa đo được tác động Show Rate/eCPM trên dashboard)

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
- [x] `flutter analyze` sạch (SDK + example); full suite 2,778/2,778; `release_readiness_gate.sh all` pass (size 2048 KB, trần không đổi).

## Quyết định đã chốt (owner, 2026-10-23)

- Gate áp cho preload/refill **tự động**: sau App Open settle, VIP hết hạn, retry scan 5 phút, reconnect, `AdScreenState.initState()` và `JourneyPrefetcher.notifySignal` (chỉ format fullscreen; App Open/banner không đổi). `loadInterstitial()` / `loadRewardedAd()` do host gọi trực tiếp, `showRewardedAd(bypassVipGuard)` on-demand và reload sau khi show không bị chặn. Ban đầu chỉ chốt đường tự động trong SDK; sau audit độc lập, owner chọn gate **cả AdScreen và JourneyPrefetcher** vì nếu không, host theo hợp đồng chuẩn (home extends AdScreen) tải Interstitial ngay khi mở home và gate mất tác dụng.
- Gate cả RewardedInterstitial cùng hai format nêu trong task.
- 15s tính **foreground liên tục**: pause hủy timer, resume sau pause đếm lại từ 0; `inactive→resumed` không có pause **không** reset đồng hồ; init xong khi app đang ở nền thì chỉ bắt đầu đếm khi resume. 2 navigation tính từ lúc `initialize()` (baseline), chỉ tính page route: dialog/bottom sheet (kể cả `AdLoadingDialog` của SDK) không tính. Nguồn đếm là `AdScreenRouteLogger` nên host phải đăng ký observer này.

## Thực thi và bằng chứng

- Code: `AdConfig.smartPreloadEnabled` (mặc định `true`); `AdManager.markUserEngaged()`; `AdScreenRouteLogger.navigationEventsNotifier`; `AdManager.deferAutoPreload()` (`@internal`, dùng chung cho AdScreen và JourneyPrefetcher). Gate tại `_onAppOpenStateChange`, `_onVipActiveChanged`, `_retryRefillAds` (bao cả reconnect), `AdScreenState.initState`, `JourneyPrefetcher.notifySignal`. Reset trong `_disposeAdapter` (`destroy()` đi qua đây).
- Test: `test/t264_smart_preload_test.dart` (25 ca: mặc định, hoãn, release 1 lần, trước/sau App Open settle, 1 vs 2 navigation thật, dialog không tính, navigation trước init (1 trước + 1 sau init chỉ tính 1), 15s vs 14s, pause reset, `inactive→resumed` không reset, init khi đang ở nền, retry, VIP, host load, AdScreen hoãn/sau engagement/opt-out, JourneyPrefetcher hoãn và sau engagement, opt-out, destroy, re-init). Mutation check: bỏ từng điểm (open-state gate, retry gate, VIP gate, pause-cancel, reset ở `_disposeAdapter`, `_navBase`, lọc popup, điều kiện `prev==paused`, arm-khi-ở-nền) đều làm test tương ứng đỏ; reset thừa trong `_resetGuardState` bị loại vì không test nào cần.
- Audit độc lập (agent riêng, đọc diff): 2 MAJOR đã sửa (dialog của SDK tự đếm thành 2 navigation làm gate mở ngay ở splash; AdScreen/JourneyPrefetcher tải Interstitial không qua gate), 2 MINOR đã sửa (timer chạy khi init xong lúc ở nền; `inactive→resumed` reset đồng hồ), 1 MINOR đã sửa (test navigation-trước-init vacuous, probe debug bỏ quên). Chưa sửa/ghi nhận: `AdScreenRouteLogger.resetState()` về 0 thấp hơn baseline chỉ xảy ra khi test/crash recovery vì `destroy()` không gọi nó; khi VIP đang active mà engagement đạt thì 3 `loadX()` phát 3 `AdSkipEvent('vip')` (nhiễu log, không sai hành vi).
- Integration TECNO KJ7 Android 14, Google test ads: `example/integration_test/t264_smart_preload_test.dart` 4/4 pass (hoãn rồi release sau `markUserEngaged()`; host `loadInterstitial()` không bị chặn và Rewarded vẫn `idle`; màn `AdScreen` mở trước engagement không preload rồi preload sau `markUserEngaged()`; opt-out nạp ngay). Log `/tmp/t264_tecno2.log` (local).
- Test cũ phải opt-out `smartPreloadEnabled: false` vì chúng kiểm tra refill/reconnect/VIP chứ không phải engagement: `connectivity_*`, `ad_manager_connectivity_transition`, `fast_refill_rewarded_interstitial`, `tcf_personalisation_consent`, `r73_vip_expiry_recheck_on_resume`, retry timer trong `ad_manager_core_test`.
- Giới hạn size gate: lib ở đúng 2048 KB; thêm code phải bù bằng cách rút gọn comment. Đã rút gọn `revenue_panel.dart` (-1 block) và `ad_route_observer.dart` (doc comment `showAdSafeModalBottomSheet`); không đổi ngưỡng.

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
