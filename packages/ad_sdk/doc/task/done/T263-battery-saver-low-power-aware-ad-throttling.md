# T263 — Tự Động Giảm Tải Quảng Cáo Khi Pin Yếu Hoặc Bật Tiết Kiệm Pin (Battery Saver Mode)

- **Loại:** Enhancement / Performance & Battery Health
- **Priority:** P2 · **Severity:** LOW
- **Status:** done (2026-10-24; host-supplied signal gates AppLovin Banner/MREC auto-refresh; OS battery sensing is outside scope)

## Discovery gate (bắt buộc trước implementation)

- [x] Discovery 2026-10-24: Android có `PowerManager.isPowerSaveMode()` và `BatteryManager`/`ACTION_BATTERY_CHANGED`; iOS có `ProcessInfo.isLowPowerModeEnabled` và `UIDevice.batteryLevel/batteryState`. Các API cần native bridge/host channel (battery percentage Android là sticky broadcast; không thấy quyền đặc biệt cần cho mức pin/Power Save, nhưng phải xác nhận trên minSdk/build cụ thể trước implementation). Chưa thêm code hoặc dependency.
- [x] Dependency scan: repo hiện không khai báo `battery_plus`/`device_info_plus`; package có Android Gradle/Kotlin, Google Mobile Ads và AppLovin CocoaPods pinning walls. Không đề xuất plugin mới trước owner approval; prefer một native channel tối thiểu hoặc API host-provided.
- [x] Đối chiếu implementation (2026-10-24): `AdSafetyParams.minTimeBetweenFullscreenAds` default hiện là 60,000ms, không phải 30s; T230 fatigue path đã tự nhân đôi throttle. Không đổi throttle lần nữa. AppLovin auto-refresh đã qua `InlineVisibilityOwners`/`autoRefreshEnabled`; AdMob Google SDK quản lý refresh native. Feature chỉ điều khiển AppLovin inline refresh, không tuyên bố điều khiển cross-provider.
- [x] Scope owner chọn: chỉ pause/resume **AppLovin Banner/MREC auto-refresh** qua owner hiện có `InlineVisibilityOwners`/`autoRefreshEnabled`. Host quyết định low-power mode/battery thresholds (nếu có), rồi gửi trạng thái boolean. Không sửa `minTimeBetweenFullscreenAds`, App Open, Interstitial/Rewarded, hoặc AdMob refresh native. Không hứa giảm nhiệt/hao pin hay doanh thu nếu chưa đo.
- [x] Public API chỉ nhận boolean do host cung cấp. OS battery/low-power detection và native channel không thuộc scope; host wiring chưa được kiểm chứng trong SDK và phải do consuming app tự triển khai nếu cần.

## Bối cảnh & Vấn đề

Feature được giới hạn vào AppLovin Banner/MREC auto-refresh. Fullscreen throttle hiện mặc định 60s và AdMob banner refresh do Google native SDK quản lý; hai phần đó không nằm trong scope vì không thể điều khiển đúng qua API Dart hiện có. Mục tiêu là tránh automatic inline refresh khi hệ điều hành báo low-power hoặc pin yếu; mức giảm nhiệt/pin cần được đo riêng, không giả định trước.

## Phạm vi đã triển khai

1. Consuming app quyết định low-power boolean, kể cả thresholds/hysteresis nếu dùng battery level.
2. Host gọi `AdManager().setLowPowerMode(bool)`; `true` pause AppLovin Banner/MREC auto-refresh, `false` releases only low-power hold.
3. SDK không tự đọc OS state; không thêm native bridge, plugin, hoặc battery-level policy.
4. AdMob native refresh, fullscreen ads/throttle, và nội dung ad đang load/show không bị điều khiển bởi API này.

## Acceptance Criteria

- [x] Host có public boolean API để gửi trạng thái đã tự quyết định; SDK không tự đọc battery hoặc Low Power Mode.
- [x] Low-power signal `true/false` pause/resume AppLovin Banner/MREC refresh qua owner `InlineVisibilityOwners`; host tự chọn thresholds/hysteresis nếu cần.
- [x] AdMob refresh, fullscreen throttle/ads và host-requested load/show không bị ảnh hưởng; các owner hiện có tiếp tục compose.
- [x] Setter idempotent, trạng thái mặc định `false`, giữ host-state qua destroy/reinitialize; AppLovin owner compose với fullscreen/route/background holds.
- [x] Không thêm dependency hay nới pinning/2048KB size gate; release gate xác nhận `lib` đúng 2048 KB.
- [x] `flutter analyze` sạch; owner/widget tests pass; SDK suite **2,785/2,785** pass; `release_readiness_gate.sh all` pass.
- [x] TECNO KJ7 smoke `example/integration_test/t263_host_low_power_signal_test.dart` **1/1 pass** với `AD_PROVIDER_ADMOB=true`; xác nhận host setter nhận true/false và không crash.
- [x] TECNO unattended integration run: **143 files completed**, script exit code 0; no retries/final failures. Six real-AppLovin/manual-dismiss files are explicitly excluded by the repo script and remain unverified in this run.
- [ ] Chưa đo battery/thermal savings; chưa kiểm chứng host OS-signal wiring hoặc chạy iOS smoke. Không tuyên bố giảm pin/nhiệt.

## Implementation evidence (2026-10-24)

- `AdManager().setLowPowerMode(bool)` host API stores the latest state (default false), persists it across destroy/reinitialize, and dispatches only to `AppLovinAdapter`; no `AdProviderAdapter` interface change, no native battery probe or dependency.
- `AppLovinAdapter` applies `InlineHideReason.lowPower` to existing Banner/MREC and reasserts it on newly created/recovered instances. Releasing low-power removes only that owner, preserving fullscreen/background/route/pendingFill holds. AdMob and fullscreen formats remain unchanged.
- Owner composition test `test/r32_banner_widget_applovin_refresh_test.dart`, focused pass. TECNO host API smoke `example/integration_test/t263_host_low_power_signal_test.dart` pass 1/1; verifies true/false calls complete without exception. Does not measure OS battery state/savings.
- Size workaround: repo release gate sums 4KB blocks for tracked `lib` files and was at 2048KB. Removed one duplicate C4 explanatory comment block in `admob_adapter.dart` while preserving the full rationale at other call sites; gate remains at 2048KB, threshold unchanged.
- SDK/example analyzer, full SDK suite (**2,785/2,785**), and release gates passed. TECNO integration script completed 143 files with exit code 0; six AppLovin/manual-dismiss files excluded by the repo script were not covered.

## Kiểm thử ngoài phạm vi

- Host tự kiểm thử OS battery/Low Power detection và threshold policy trên nền tảng của mình nếu cần; SDK chỉ nhận boolean đã được host quyết định.
- Đo battery/thermal impact riêng trước khi đưa ra tuyên bố tiết kiệm pin/nhiệt.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T263 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/ad_safety_config.dart, lib/src/core/ad_manager.dart.
2. Viết test trước để kiểm tra hành vi thích ứng theo pin (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
