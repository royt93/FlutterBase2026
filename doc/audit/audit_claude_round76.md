# Audit Claude round 76 — independent SDK + example review

Ngày: 2026-10-25  
Package: `applovin_admob_sdk` **3.6.0**  
Baseline: `f3e163095e37bf7b7ba92bbe57d53ee8b37dc5ed` (`main`)  
Phạm vi: package source, example, tests, Android/iOS integration/configuration, pub.dev archive, consent/privacy, VIP/trial, lifecycle/offline, policy and production suitability.

## Kết luận

**Không có cơ sở để gọi SDK này kém hoặc có hành vi quảng cáo lén. Có thể cân nhắc production với điều kiện; chưa đủ bằng chứng để phê duyệt vô điều kiện cho toàn bộ ma trận Android/iOS × AdMob/AppLovin.** Source cho thấy kiến trúc provider riêng, state/lifecycle gates, consent signals, offline handling và VIP ký Ed25519 được xây dựng nghiêm túc. Toàn bộ SDK tests, analyzer và release readiness gate đều xanh trong checkout này. Tuy vậy, có một lỗi refresh native AppLovin được xác nhận bằng trace source, và thiếu xác nhận thực tế trên iOS/AppLovin, full-screen dismissal, consent UI và memory profile.

Kết luận này đánh giá code và bằng chứng hiện có, **không phải xác nhận pháp lý hoặc đảm bảo tài khoản quảng cáo sẽ tuân thủ policy**. Host app vẫn phải chọn đúng cấu hình CMP/UMP, disclosures, ad placements, tài khoản/đối tác và các tín hiệu dành cho nhóm tuổi/thị trường của mình.

## Baseline và bản pub.dev

- pub.dev latest tại thời điểm kiểm tra: **3.6.0**, phát hành `2026-10-25T10:09:19.182540Z`.
- Local package version và git HEAD cùng là `3.6.0` / `f3e163095e37bf7b7ba92bbe57d53ee8b37dc5ed`.
- Tải archive từ pub.dev; SHA-256 `766b0187903dd4dfa58eb3744b38d5f129d0110d1294b25d8924c3f8fb539180`, khớp metadata pub.dev.
- So sánh nội dung `lib/` và `example/lib/`: khớp; chỉ có `.DS_Store` cục bộ. Khác biệt platform/tooling chủ yếu là file build/generated/local không nằm trong archive, không phải khác biệt source đã kiểm tra. Do đó findings source dưới đây áp dụng cho bản 3.6.0 đã publish.
- Worktree sạch trước/sau audit; không sửa source/dependency/version.

## Finding đã xác minh

### R76-01 — MINOR — `InlineAdController.refresh()` không remount native view AppLovin

**Vị trí:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:457-470`, `:446-452`, `:735-788`, `:845-867`, `:880-912`; `packages/ad_sdk/lib/src/widget/inline_ad_controller.dart:95-103`; kiểm thử hiện tại `packages/ad_sdk/test/inline_ad_controller_widget_test.dart:565-625`.

Khi controller đang active và AppLovin native ad đã mount, `controllerRefresh()` huỷ per-instance adapter state và đặt `_allowed=false`, rồi đồng bộ gọi `_initNative()`. `_initNative()` đặt `_allowed=true`, nhưng nhánh AppLovin chỉ ghi log rằng `MaxNativeAdView` tự tải khi mount; nó không gọi API reload. Hai thay đổi notifier xảy ra trước frame kế tiếp, nên subtree thấy giá trị cuối `true` và giữ nguyên `MaxNativeAdView`/platform-view State. Trong `applovin_max 4.6.4`, load gắn với lúc view được tạo; không remount đồng nghĩa không có request mới. `isLoaded` vừa reset vẫn false, làm shimmer phủ creative cũ và impression/revenue mới không phát sinh. Người dùng có thể thấy ad cũ dưới lớp shimmer cho tới khi một lifecycle event khác khiến view remount.

**Tái hiện theo source:** mount AppLovin `NativeAdWidget(controller: controller)` và đợi loaded; gọi `controller.refresh()` khi controller active. Adapter notifiers reset, nhưng cùng `MaxNativeAdView` giữ nguyên State; không có lần load mới. Kiểm tra đối chiếu `InlineAdController.refresh()` hiện tại chỉ kiểm tra AdMob qua fake adapter (`inline_ad_controller_widget_test.dart:613-624`); chưa có test tương đương AppLovin. Đây là static trace có API lifecycle của dependency hỗ trợ, chưa được xác nhận bằng ad fill thật trên thiết bị.

**Tác động:** refresh thủ công không làm mới creative và để trạng thái UI/loading không đồng bộ. Không phải lỗi xin ad trái phép hay crash; workaround là remount widget (ví dụ đổi key) hoặc pause/resume để view thật sự bị tháo/lắp.

**Khuyến nghị:** sửa bằng cách đảm bảo native view AppLovin unmount/remount khi refresh; thêm widget regression test kiểm tra State/key của `MaxNativeAdView` thay đổi và notifier trở lại loaded khi callback giả được kích hoạt. Thêm integration test native khi có môi trường AppLovin QA hợp lệ.

## Các phần đã rà — không có finding mới xác nhận

- **Provider/init:** `AdMobAdapter` và `AppLovinAdapter` qua boundary `AdProviderAdapter`; chọn provider tại init. Không thấy bằng chứng tự chuyển provider trong session.
- **Lifecycle/callback:** kiểm tra slot transitions, watchdog, dispose, late callback identity và per-instance registry; adapter ownership được tách. Không thấy leak cụ thể được chứng minh từ source. Chưa thay thế native heap/profile lặp load/show/dispose.
- **Consent/privacy:** xem UMP, ATT, TCF/GPP/IAB storage, COPPA/TFUA, CCPA/RDP và đường withdrawal. Source có fail-closed paths cho lỗi đọc IAB và giới hạn rõ với các API AppLovin fire-and-forget. Không thể suy ra “tuân thủ mọi quốc gia” chỉ từ SDK; consent requirement phụ thuộc pháp vực, CMP, cấu hình dashboard, app và đối tác. Round 75 đã ghi R75-01/02 và trạng thái khắc phục; round này không tìm thấy regression mới trong các đường đó.
- **VIP/trial không backend:** Ed25519 verification, expiry/bundle binding, CRL, local redemption ledger và trial 24 giờ có hiện thực. Không thể bảo đảm single-use toàn cầu hoặc chống người dùng kiểm soát thiết bị/storage khi không có server; Android anti-reinstall best-effort. Đây là giới hạn kiến trúc/đã được chấp nhận trong `CLAUDE.md`, không tính là lỗi mới.
- **Compliance signing:** chữ ký tự chứa public key chứng minh nội dung khớp key trong report, không chứng minh danh tính người phát hành/thiết bị. Giới hạn này đã được ghi rõ trong `lib/src/compliance/compliance_signing.dart:17-23`; không xem “VALID” là identity attestation.
- **Example/config:** example có navigator/route observer, consent/init ở splash và platform metadata/plugin setup mẫu. Nó là demo, không phải app template hoàn chỉnh; AppLovin dùng placeholder key/IDs và CI không chạy inventory AppLovin.
- **Test gaps đáng chú ý:** CI buộc AdMob; AppLovin real-ad path, automated fullscreen dismiss, UMP/ATT native UI end-to-end chưa có bằng chứng CI tương đương. iOS runtime, offline/reconnect trên mọi format/provider và memory profile cần kiểm tra riêng.

## Kiểm thử và bằng chứng

| Kiểm tra | Kết quả | Giới hạn |
|---|---|---|
| `flutter analyze lib/ test/ example/lib/` | `No issues found!`, exit 0 | Static analysis, không chứng minh platform runtime |
| `./tool/release_readiness_gate.sh all` | `release gate: all passed`, exit 0 | Gate repo hiện hành |
| `flutter test --reporter=compact` | **2,802 tests passed**, `All tests passed!`, exit 0 | SDK VM/widget suite; không thay native matrix |
| `flutter test test/signed_export_cli_test.dart --reporter=compact` | **10 tests passed**, exit 0 | Chạy lại độc lập sau khi một focused agent gặp stdout mismatch; không tái hiện lỗi trên Dart 3.11.5 checkout này | 
| pub.dev archive compare | `lib/` và `example/lib/` khớp checkout | Không đồng nghĩa mọi local generated/build files thuộc archive |
| iOS / AppLovin / live dialogs / memory | Không chạy trong lượt audit | Cần thiết bị/simulator và AppLovin QA setup; không dùng production inventory |

## Đánh giá theo yêu cầu sản phẩm

| Yêu cầu | Đánh giá độc lập |
|---|---|
| AdMob/AppLovin trên Android + iOS | Có adapter/plugin integration. Bằng chứng audit hiện tại không đủ để bảo chứng cả bốn tổ hợp bằng thiết bị thật; AppLovin CI/native kiểm chứng yếu nhất. |
| Có mạng / mất mạng | Gate và reconnect/refill có xử lý. Mất mạng thì không thể đảm bảo có ad mới; cần device test cold-start/offline/mid-load/reconnect từng provider/format. |
| Banner, App Open, rewarded, interstitial; vòng đời | Có state machine và cơ chế cleanup/watchdog. Native AppLovin refresh có finding R76-01; các full-screen dismiss/teardown chưa đủ automation. |
| Trial 1 ngày | Release mặc định 24 giờ; chống cài lại không tuyệt đối, nhất là Android. Không hứa trial bất khả lạm dụng. |
| VIP code, không backend | Chữ ký Ed25519 tốt cho xác minh offline sau khi có grant; cần mạng lúc kích hoạt theo quyết định sản phẩm. Không thể chống replay đa thiết bị/key leak hoặc kiểm soát storage với bảo đảm server-side. |
| Consent và policy | Tín hiệu kỹ thuật có diện rộng; SDK không thể tự chứng nhận tuân thủ luật/policy toàn cầu. Chủ app chịu trách nhiệm cách dùng và disclosure. |
| Memory leak | Source có dispose/identity guards; chưa có profiling thực nghiệm, nên không tuyên bố “không leak”. |

## Verdict production

**Có thể đưa vào production có kiểm soát sau khi xử lý R76-01 và hoàn thành smoke test cho đúng platform/provider mà ứng dụng sẽ phát hành. Không nên coi 2,802 test pass hoặc release gate pass là chứng nhận production cho iOS/AppLovin.** Với app chỉ dùng Android + AdMob, rủi ro thấp hơn nhưng vẫn cần regression native và kiểm thử reconnect/consent trên thiết bị của app. Với iOS hoặc AppLovin, yêu cầu build/run thật, ATT/UMP/withdrawal, native ad lifecycle và callback dismissal trước release. Dùng key/ad unit QA hợp lệ; không kiểm tra bằng production inventory.
