# T140 — Tính năng mới: Placement Registry tập trung

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P2
- **Status:** 🔲 todo
- **Effort:** L
- **Files (dự kiến):** `lib/src/config/ad_config.dart` (nơi `bannerId`/
  `interstitialId`/`rewardedId`/... hiện là required param riêng lẻ trên
  `AdMobConfig`/`AppLovinConfig`, dòng ~107-160), file mới
  `lib/src/config/placement_registry.dart`, các API show ad trong
  `lib/src/core/ad_manager.dart` (`showInterstitialAd`, `showRewardedAd`, ...)
- **Nguồn gợi ý:** codex
- **Dependency:** không có

## Vấn đề

Ad unit ID hiện khai báo trực tiếp trong constructor `AdMobConfig`/
`AppLovinConfig` (`ad_config.dart:107-160`), mỗi format 1 field riêng
(`bannerId`, `interstitialId`, `rewardedId`, `rewardedInterstitialId`,
`nativeId`, `mrecId`, `appOpenId`). Không có khái niệm "placement" tách biệt
khỏi "ad unit id" — nếu app có 2 vị trí hiển thị interstitial khác nhau
(vd "sau khi hoàn thành level" vs "khi thoát app") muốn dùng frequency cap
hoặc reward amount khác nhau, không có chỗ khai báo tập trung — phải tự
quản lý bằng biến riêng ở tầng app.

## Việc cần làm

- [ ] Thiết kế `class PlacementRegistry` — map `placementId (String) →
      PlacementSpec { AdSlotType format, int? frequencyCapOverride, ... }`.
      KHÔNG lưu ad unit ID trong registry này (ad unit ID vẫn ở
      `AdMobConfig`/`AppLovinConfig` như cũ, tránh trùng lặp nguồn sự thật) —
      registry chỉ map placementId → override behavior (cap, reward context).
- [ ] Thêm optional `String? placementId` vào các method show
      (`showInterstitialAd`, `showRewardedAd`, ...) — khi có, tra
      `PlacementRegistry` để áp override; khi không có (mặc định), giữ
      NGUYÊN behavior hiện tại 100% (backward-compat).
- [ ] `AdConfig` nhận optional `PlacementRegistry? placements` — mặc định
      `null` = tắt tính năng, không ảnh hưởng app hiện có.
- [ ] Unit test: có placementId → override cap áp dụng đúng; không có
      placementId → behavior y hệt trước khi có tính năng này.
- [ ] Cập nhật README thêm 1 mục ngắn giới thiệu tính năng optional này.

## Ghi chú

Effort L vì đụng nhiều call site show-ad hiện có (interstitial/rewarded/
rewarded-interstitial/app-open) — mỗi cái cần thêm tham số optional và test
riêng cho path "có placementId". Rủi ro chính: đừng để registry trở thành
nguồn sự thật THỨ HAI cho ad unit ID (dễ gây nhầm lẫn/desync với
`AdMobConfig`/`AppLovinConfig` đã có) — registry chỉ nên quản lý
BEHAVIOR override, không quản lý ID.

## Kết quả (2026-09-06) — DONE

- **Status:** ✅ done. **Điểm cuối: 9.1/10** (2 vòng review độc lập `codex`:
  8.7/10 → 9.1/10).
- **Điều chỉnh thiết kế quan trọng so với mô tả ban đầu**: ticket viết
  "thêm optional `String? placementId` vào các method show" — nhưng đọc
  code thật phát hiện `showInterstitial`/`showRewardedAd`/... **ĐÃ CÓ SẴN**
  tham số `placement: AdPlacement` (và `AdPlacement.id` đã là `String`).
  Thêm 1 tham số `placementId` MỚI sẽ tạo ra 2 khái niệm trùng lặp cho
  CÙNG 1 thứ (placement identity) — đúng loại rủi ro ticket tự cảnh báo
  ("đừng để... nguồn sự thật thứ hai") nhưng áp dụng cho identity chứ
  không chỉ ad unit ID. Quyết định: KHÔNG thêm tham số mới —
  `PlacementRegistry` tra cứu qua `AdPlacement.id` đã có sẵn. Cả 2 vòng
  review độc lập đều xác nhận điều chỉnh này đúng với ý định thật của
  ticket, không phải bỏ sót scope.
- **Vòng 1 (8.7/10) — 2 finding Important:**
  1. `PlacementSpec.format` required nhưng KHÔNG được check ở runtime —
     spec đăng ký cho `interstitial` vẫn âm thầm chặn `showRewardedAd`
     nếu host vô tình tái dùng cùng `AdPlacement.id`. Sửa:
     `_placementCapOverride` giờ nhận thêm `AdSlotType actualFormat`,
     chỉ trả override khi `spec.format == actualFormat` khớp.
  2. Test chỉ cover `showInterstitial`, thiếu appOpen/rewarded/
     rewardedInterstitial dù đây chính là lý do Effort L. Thêm test cho
     cả 4 format + 1 test format-mismatch + 1 test riêng
     `bypassSafety: true` vẫn bypass hoàn toàn (không bị T140 phá vỡ).
- **Vòng 2 (9.1/10) — 1 finding Important:** doc comment cũ của
  `PlacementSpec.format` nói "không được enforce ở runtime" — MÂU THUẪN
  với chính fix vừa sửa ở vòng 1 (giờ CÓ enforce). Đã sửa lại doc comment
  cho khớp hành vi thật.
- Baseline: `flutter analyze` sạch; `flutter test` 1717/1717; integration
  test `t140_placement_registry_test.dart` (cả interstitial VÀ rewarded)
  pass thật trên Samsung Galaxy S24 Ultra (Pixel 7 Pro mất kết nối giữa
  session) — phải tắt `firstInstallVipGrace` vì debug build mặc định cấp
  VIP grace che mất gate cần test.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T140-placement-registry.md này (nếu đã chuyển
inprogress/done thì đọc ở đó). Implement ĐÚNG scope "Việc cần làm" — KHÔNG
thêm scope ngoài mô tả.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có, không tự dựng server/API mới. Nếu ticket
này có vẻ cần backend, dừng lại hỏi user trước khi code.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp: sửa → audit adversarial (codex/agy độc lập trong bản copy cô lập /tmp,
rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R nguyên khối) → nếu
≤9/10 sửa tiếp → verify lại → lặp tới ≥9/10 mới push. KHÔNG tự ý push nếu
chưa đạt ngưỡng. Di chuyển ticket từ todo/ → inprogress/ khi bắt đầu, →
done/ khi xong.
```
