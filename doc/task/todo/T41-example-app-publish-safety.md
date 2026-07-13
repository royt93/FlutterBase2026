# T41 — `packages/ad_sdk/example/` không an toàn để publish nguyên trạng

- **REQ:** ngoài phạm vi 7 yêu cầu gốc — phát hiện từ `doc/audit/audit_codex.md` (2026-07-13)
- **Priority:** P0/P1-theo-codex (chỉ ảnh hưởng example app, không ảnh hưởng host app đang ship) · **Status:** 📋 todo
- **Files:** `packages/ad_sdk/example/lib/main.dart:44-64,145-189`, `packages/ad_sdk/example/ios/Runner/Info.plist:50-51`

## Vấn đề (Why)
Gộp 2 phát hiện liên quan của `audit_codex.md`, cùng chung nguyên nhân "example app hiện tại chỉ dùng để dev/test nội bộ, chưa từng được rà lại cho việc publish công khai":
1. **Real production AppLovin ID**: `main.dart:44-64` tự ghi chú là mượn key/ad-unit ID production thật; `example/ios/Runner/Info.plist:50-51` cũng có `AppLovinSdkKey` thật. Nếu publish nguyên trạng, traffic/revenue thật sẽ bị ảnh hưởng, và ai copy pattern này sẽ học theo cách làm không an toàn.
2. **QA safety preset ở mọi mode**: `main.dart:145-189` set session/hour/day cap = 999, CTR threshold = 1.0 — kể cả ở release build. Hợp lý cho việc test lặp lại ad UI, nhưng không chấp nhận được nếu ai đó dùng example này làm template thật.

## Giải pháp đề xuất
- Thay ID thật bằng placeholder hoặc `--dart-define`, dời ID thật ra file local không commit.
- Đổi default sang `AdSafetyParams.auto`, chỉ bật preset lỏng qua `--dart-define=QA_AD_STRESS=true`.
- Cân nhắc thêm CI check chặn publish nếu phát hiện ID thật còn sót trong `packages/ad_sdk/example/`.

## Acceptance criteria
- [ ] Không còn ID AppLovin thật hard-code trong `example/` (Dart + iOS Info.plist).
- [ ] Safety preset mặc định của example ở mức production-safe; preset lỏng chỉ bật qua flag tường minh.
- [ ] Ghi chú rõ trong README/feature.md: example app không phải template production, cần review trước khi publish/copy.
