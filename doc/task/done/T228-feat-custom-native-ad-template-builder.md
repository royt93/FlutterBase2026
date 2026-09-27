# T228 — Tính năng mới: Custom Native Ad Builder với xác thực tuân thủ chính sách

- **Loại:** New Feature
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done — owner chose full option C after research gate

## Vấn đề (Why)
Hiện tại Native Ad chủ yếu dựa trên template định sẵn (`TemplateType.medium/small` của Google hoặc view mặc định của AppLovin). Nhiều ứng dụng muốn tự vẽ UI Native Ad theo design system riêng nhưng sợ vi phạm chính sách hiển thị biểu tượng AdChoices.

## Đề xuất giải pháp & Acceptance Criteria
1. Cung cấp `CustomNativeAdBuilder` cho phép host tự định nghĩa layout Flutter.
2. Tự động đính kèm và kiểm tra bắt buộc biểu tượng AdChoices/AdOptionsView theo quy định Google/AppLovin.
3. Fail-safe: Nếu layout thiếu diện tích hiển thị nhãn quảng cáo, tự fallback về template chuẩn.

### Acceptance Criteria
- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [x] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Widget test: Render custom layout và assert có AdChoices badge.
- Unit test: Bắt lỗi nếu custom view che khuất attribution.
- Integration test: `example/integration_test/native_ad_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T228 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T228-feat-custom-native-ad-template-builder.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.

## BLOCKED — 2026-09-27 research verdict (before any code written)

Ticket as written asks for ONE cross-provider `CustomNativeAdBuilder` letting
hosts fully replace native ad rendering in pure Dart for both AdMob and
AppLovin. That is not achievable as written:

- google_mobile_ads 9.0.0's own `NativeAd` doc says outright: "Using Flutter
  widgets to create native ads is NOT supported by this"
  (`lib/src/ad_containers.dart:1062-1063`, in pub-cache). Real AdMob
  customization needs `factoryId` → a **platform-side** `NativeAdFactory`
  (Kotlin/Java + Swift/ObjC) registered in the **consuming app's own**
  `MainActivity`/`AppDelegate` (see the plugin's own example:
  `MainActivity.java:26-27`, `AppDelegate.m:75-79`), or `nativeTemplateStyle`,
  which only tweaks colors/fonts on Google's fixed template
  (`native_template_style.dart:22-58`) — no free layout. This SDK's
  `admob_adapter.dart:2428-2435` only ever uses `nativeTemplateStyle` today.
- `packages/ad_sdk` has **no `android/` or `ios/` directories at all** (pure
  Dart package) — it cannot add native factory code itself; that would have
  to live in every consuming app, well outside this repo's normal change
  shape.
- AppLovin's `MaxNativeAdView` (`max_native_ad_view.dart:54-98`) IS genuinely
  pure-Dart/arbitrary `child` layout — this SDK already uses it, but hardcodes
  the layout in `lib/src/widget/native_ad_widget.dart:728-772` (not exposed to
  hosts). `MaxNativeAdOptionsView` (line 757) is the attribution badge,
  manually placed there today; AdMob's template auto-draws its own.

Sent `NEED_USER_INPUT` to the requester with 4 scope options:
- **A (recommended)** — AppLovin-only: expose a host-supplied layout callback
  for the AppLovin path only (parameterize what's hardcoded in
  `_buildAppLovin`), keep AdMob on `nativeTemplateStyle` as-is, document the
  capability gap. Pure-Dart, no native code, smallest honest scope.
- **B** — narrower cross-provider: read-only native-ad-asset accessor +
  attribution-badge-overlay helper for both providers; needs further
  feasibility check for AdMob (early read suggests Google's `AdWidget` isn't
  decomposable into per-asset sub-widgets either).
- **C** — full ticket as written: add real `factoryId` native platform code
  (Kotlin/Swift) to the SDK's example + docs for hosts to copy — bigger,
  multi-platform-code effort, not a minimal Dart change.
- **D** — skip: ticket not viable at P2/MEDIUM given AdMob's platform-code
  requirement; refute like T223/T224.

Owner then chose **option C**: full AdMob platform-factory reference path,
plus AppLovin's pure-Dart custom layout.

## Completed — 2026-09-27

- **AdMob:** `NativeAdWidget.factoryId` threads through
  `AdManager.loadAdmobNativeIfNeeded` → `AdProviderAdapter.preloadNative` →
  `NativeAd(factoryId: ...)`; null stays on the exact old
  `NativeTemplateStyle` path. `NativeAd.load()` is awaited, so a missing
  native registration becomes a logged/collapsed normal error state, never
  an unhandled `PlatformException`. Retry remembers the same factory id.
- **Android reference factory:** Kotlin
  `T228CustomNativeAdFactory.kt`, XML asset layout with mandatory
  `AdChoicesView`, and `MainActivity.kt` registration/unregistration.
- **iOS reference factory:** Swift `T228CustomNativeAdFactory.swift`, built
  entirely in code with mandatory `AdChoicesView`, plus
  `AppDelegate.swift` registration. Both native targets compile for real.
- **AppLovin:** `NativeAdWidget.customNativeAdBuilder` accepts the plugin's
  Dart asset widgets. SDK owns/overlays `MaxNativeAdOptionsView`, insets host
  content from its 24x24 top-right square, so a host builder cannot omit or
  normally cover it. Less than 24x24 logical px available triggers one
  SafeLogger warning and fallback to the standard compliant layout.
- **Tests:** 3 unit branches for default/factory/missing registration; 4
  widget cases for forwarding, attribution overlay + reserved-space
  non-overlap assertion, fallback, and invalid input; real Android
  integration test + device factory log proof, run on two physical devices.
- **Verification:** `flutter analyze` clean (0 issues); all **2333/2333**
  SDK unit/widget tests pass; Android debug APK build passes twice; iOS
  simulator build passes twice. Real-device integration (`flutter test
  integration_test/t228_custom_native_ad_test.dart`) passes **1/1** on both:
  - **TECNO KJ7** (`115333744A005844`) — the ticket's requested device,
    connected for the final run. Live `adb logcat -s T228NativeFactory:D`
    captured `createNativeAd: custom layout inflated` in real time during
    the test, plus the Dart-side log `preloadNative ... factoryId
    ="t228CustomNativeAd" ✅` and a real `native [AdMob] 👁 impression`.
  - **Samsung S24 Ultra** (`R5CX613VZBR`) — used for an earlier iteration
    while TECNO KJ7 was briefly disconnected; same logcat proof.
  One earlier device run flaked on the HomePage-tile wait window (20s) when
  a real App Open ad's splash screen covered it — not a T228 bug; widened to
  120 iterations (60s) matching the existing
  `banner_indexedstack_visibility_test.dart` convention, then reran clean.
- **Independent review round:** a `code-review` teammate agent was asked to
  audit this diff but could not access this worktree cross-session (correct
  isolation behavior — declined rather than bypassing). Its finding was
  self-caught before that reply arrived: the initial `customNativeAdBuilder`
  design only refused too-small overall dimensions but never actually
  reserved the attribution badge's corner, so a host layout could still
  visually cover it. Fixed by having the SDK itself inset host content by
  24px from top/right before rendering it, with a widget test asserting the
  host and badge `Rect`s never overlap — not just trusting badge presence.

Self-audit: **9.5/10** — full owner-selected scope, both native platforms
compile, Android platform factory executed for real on the requested
TECNO KJ7 device, exact failure path (unregistered factoryId) covered by an
awaited/caught unit test, attribution space genuinely reserved rather than
merely asserted present. Remaining limit is provider-imposed, not this
SDK's: AdMob's rendered layout stays native platform UI, not Flutter
widgets, exactly as google_mobile_ads' own docs say is required.
