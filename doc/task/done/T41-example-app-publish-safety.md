# T41 — `packages/ad_sdk/example/` không an toàn để publish nguyên trạng

- **REQ:** ngoài phạm vi 7 yêu cầu gốc — phát hiện từ `doc/audit/audit_codex.md` (2026-07-13)
- **Priority:** P0/P1-theo-codex (chỉ ảnh hưởng example app, không ảnh hưởng host app đang ship) · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/example/lib/main.dart`, `packages/ad_sdk/example/ios/Runner/Info.plist`

## Vấn đề (Why)
Gộp 2 phát hiện liên quan của `audit_codex.md`, cùng chung nguyên nhân "example app hiện tại chỉ dùng để dev/test nội bộ, chưa từng được rà lại cho việc publish công khai":
1. **Real production AppLovin ID**: `main.dart:44-64` tự ghi chú là mượn key/ad-unit ID production thật; `example/ios/Runner/Info.plist:50-51` cũng có `AppLovinSdkKey` thật (và `GADApplicationIdentifier` cũng là App ID thật của host app, không phải Google test App ID). Nếu publish nguyên trạng, traffic/revenue thật sẽ bị ảnh hưởng, và ai copy pattern này sẽ học theo cách làm không an toàn.
2. **QA safety preset ở mọi mode**: `main.dart:145-189` set session/hour/day cap = 999, CTR threshold = 1.0 — kể cả ở release build. Hợp lý cho việc test lặp lại ad UI, nhưng không chấp nhận được nếu ai đó dùng example này làm template thật.

## Giải pháp đã chọn
- **AppLovin ID (Dart)**: `_kAppLovinSdkKey` + 4 ad-unit ID đổi sang `String.fromEnvironment(...)` với `defaultValue` là placeholder `YOUR_*` — không còn ID thật nào commit vào source. Ai cần chạy real-ID audit cục bộ pass `--dart-define=APPLOVIN_SDK_KEY=...` (+ `_BANNER_ID_IOS`/`_BANNER_ID_ANDROID`/`_INTERSTITIAL_ID_*`/`_APPOPEN_ID_*`/`_REWARDED_ID_*`).
- **iOS Info.plist**: `GADApplicationIdentifier` đổi sang Google test App ID cho iOS (`ca-app-pub-3940256099942544~1458002511`, khớp pattern test App ID Android manifest đã dùng sẵn `~3347511713`). `AppLovinSdkKey` đổi sang placeholder — key này không được SDK dùng thật (Dart code init AppLovin programmatically qua bridge), chỉ là fallback native không cần thiết.
- **Safety preset**: thêm `kQaAdStress = bool.fromEnvironment('QA_AD_STRESS')`. `DemoConfig.build()` dùng `kQaAdStress ? kDemoSafetyParams : AdSafetyParams.auto` — mặc định production-safe như app thật, preset lỏng (999 caps/CTR off) chỉ bật khi pass `--dart-define=QA_AD_STRESS=true`.
- **Không làm** (cân nhắc, optional trong task doc, scope out theo YAGNI): CI check tự động chặn publish nếu phát hiện ID thật còn sót trong `example/`. Grep thủ công đã xác nhận sạch tại thời điểm fix; nếu muốn enforce lâu dài, thêm sau khi có nhu cầu thực tế (ví dụ một lần leak lại xảy ra).

## Acceptance criteria
- [x] Không còn ID AppLovin thật hard-code trong `example/` (Dart + iOS Info.plist) — verify bằng grep 9 chuỗi ID thật cũ, không match.
- [x] Safety preset mặc định của example ở mức production-safe (`AdSafetyParams.auto`); preset lỏng chỉ bật qua flag tường minh (`QA_AD_STRESS=true`).
- [x] Ghi chú rõ trong `doc/feature.md`: example app không phải template production, cần review trước khi publish/copy.

## Verify
`cd packages/ad_sdk/example && flutter test` → 12/12 pass. `flutter analyze` → no issues. `grep -rn "<real ID strings>" example/` → no output.
