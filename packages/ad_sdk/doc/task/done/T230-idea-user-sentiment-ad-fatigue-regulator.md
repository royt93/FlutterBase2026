# T230 — Ý tưởng: Bộ điều tiết tần suất quảng cáo dựa trên phản ứng người dùng

- **Loại:** Idea
- **Priority:** P3 · **Severity:** LOW
- **Status:** ✅ done

## Kết quả thực tế (Completion evidence, 2026-09-28)

**Verdict: real fix/extension of `AdSafetyConfig`, KHÔNG tạo class
`AdFatigueRegulator` đứng riêng** — vi phạm nguyên tắc "không tạo
abstraction thừa" nếu tách riêng, vì state (fast-close streak) cùng vòng
đời với các counter fullscreen khác đã có sẵn trong `AdSafetyConfig`.

- `AdSafetyConfig` (`packages/ad_sdk/lib/src/core/ad_safety_config.dart`):
  theo dõi `_consecutiveFastCloses` (dismiss < 1000ms) qua đối số
  `showDurationMs` mới (optional, mặc định `null` — không phá API cũ) của
  `recordFullscreenAdShown()`. `debugIsAdFatigued` getter (test-only).
  2 lần fast-close liên tiếp → gấp đôi `minTimeBetweenFullscreenAds` cho
  tới khi có 1 lần dismiss "khỏe mạnh" (≥1000ms) mới reset về bình thường.
  Reset cả trong `resetSession`/`resetSessionCounters`/`resetForReinit`.
  Tách biệt hoàn toàn khỏi `suspiciousViolationCount`/`policyRiskScore`
  (tín hiệu UX pacing, không phải gian lận).
- `AdManager` (`lib/src/core/ad_manager.dart`): cả 4 luồng show fullscreen
  (interstitial, rewarded, rewardedInterstitial, appOpen) đo thời gian
  show→dismiss bằng `Stopwatch` monotonic (không dùng `DateTime.now()` 2
  lần — tránh lệch giờ hệ thống làm sai fast-close), chỉ forward khi ad
  THỰC SỰ đã hiện + đã dismiss (không tính khi throw/skip/blocked/
  shown:false).
- Test: 8 unit test fatigue trong `test/ad_safety_config_test.dart` + 14
  wiring test qua `AdManager().show*` thực (không gọi thẳng
  `AdSafetyConfig`) trong `test/ad_manager_core_test.dart` — tổng
  `flutter test test/ad_safety_config_test.dart test/ad_manager_core_test.dart
  test/api_golden_test.dart` = **383/383 pass** (93+288+2).
- Mutation-proof: gỡ tạm guard `if (result.shown)` quanh
  `recordFullscreenAdShown()` trong `showRewardedAd` → test "rewarded:
  shown:false ... does not create a streak" đỏ ngay (RED: expected false,
  actual true), phục hồi bằng chỉnh sửa tại chỗ (revert đúng dòng đã sửa,
  diff khớp lại chính xác +21/-4 như trước) → 383/383 xanh lại (GREEN).
  Xác nhận guard là code thật đang chạy, không phải test giả.
- Lưu ý: chưa viết integration test riêng cho T230 (fast-close qua
  `AdManager` thật trên device). `creative_fatigue_guard_test.dart` có sẵn
  là của T126 (network fatigue window), không liên quan fast-close T230 —
  AC #3 dưới đây (Unit+Widget+Integration đầy đủ) chưa đạt 100%; phần
  unit/wiring (widget-level, dùng `_FakeAdapter`) coi như đủ theo yêu cầu
  "không chạy full suite/integration trong pass này, để dành bước audit
  chung với T229".
- `flutter analyze`: sạch, 0 cảnh báo.
- `test/goldens/public_api_surface.txt`: khớp chính xác với
  `dart run tool/api_surface.dart` (banner CLI "Running build hooks..."
  không tính, do `api_golden_test.dart` gọi thẳng hàm generator, không qua
  CLI).
- `CHANGELOG.md`: mục Unreleased mô tả đúng thay đổi API
  (`recordFullscreenAdShown` thêm `showDurationMs` optional).
- Chưa chạy integration test on-device / full suite trong pass này — theo
  yêu cầu, để dành cho bước audit/integration chung với T229.

## Vấn đề (Why)
Nếu người dùng bấm đóng quảng cáo ngay khi vừa hiện nút X (fast close < 1s), hoặc liên tục bấm quay lại, đây là tín hiệu ức chế quảng cáo (ad fatigue). Ép xem tiếp sẽ dẫn đến gỡ app hoặc đánh giá 1 sao.

## Đề xuất giải pháp & Acceptance Criteria
1. `AdFatigueRegulator` ghi nhận thời gian tương tác với ad fullscreen.
2. Nếu phát hiện liên tiếp 2 lần đóng vội, tự động giãn thời gian cooldown giữa 2 lần quảng cáo (vd từ 30s lên 60s).
3. Tự phục hồi về ngưỡng chuẩn sau một khoảng thời gian phiên bình thường.

### Acceptance Criteria
- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi
      (mở rộng `AdSafetyConfig` có sẵn thay vì class mới).
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner (tách
      biệt hoàn toàn khỏi CTR/policyRiskScore — không đụng owner-approved
      product decisions nào trong CLAUDE.md).
- [~] Bộ kiểm thử: Unit (8) + Widget/wiring qua `AdManager` thật với fake
      adapter (14) đầy đủ. Integration test thật trên device/simulator
      CHƯA viết trong pass này (để dành bước audit/integration chung với
      T229 theo chỉ định của task điều phối).
- [x] `flutter analyze` sạch 0 cảnh báo; `flutter test` cho 3 file liên
      quan trực tiếp (383/383) pass xanh. Full suite chưa chạy lại trong
      pass này (theo chỉ định — dành cho bước audit chung).

## Kế hoạch kiểm thử
- Unit test: Tính toán độ mệt mỏi và điều chỉnh cooldown linh hoạt.
- Integration test: `example/integration_test/creative_fatigue_guard_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T230 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T230-idea-user-sentiment-ad-fatigue-regulator.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
