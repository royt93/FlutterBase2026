# T03 — Không impression nào trước khi consent resolved (splash App Open)

- **REQ:** 7 (policy), 6 (consent)
- **Priority:** P0 · **Severity:** CRITICAL · **Status:** ✅ done (2026-07-05)

## Kết quả
- Gate consent áp cho **show paths**: `showAppOpenAd` (kể cả `bypassSafety:true` của splash), `showInterstitial`, `showRewardedAd` — không impression khi `canRequestAds=false`. Path `vipAutoGrant`-không-hiển-thị-ad vẫn cho phép (không tạo impression).
- Kết hợp với gate load (T01) + auto-UMP-await trong `initialize` (khi `autoRequestUmpConsent=true`, await UMP TRƯỚC load đầu) ⇒ không ad nào bắn trước khi consent resolved.
- Verify device: host splash chạy ATT→UMP→setConsent (buffered) trước init — bằng chứng ordering đúng.
- Test: show-gate trong `test/consent_gate_test.dart`. **266/266 xanh**.
- **Files:** `core/ad_manager.dart` (`initialize` `:591`, `showAppOpenAd` `:879`, splash flow `:213-332`), host `lib/mckimquyen/widget/splash/`

## Vấn đề (Why)
`initialize()` gọi `unawaited(loadAppOpenAd())` ngay (`:591`) và splash `showAppOpenAd(bypassSafety:true)`. Dialog consent lại lên lịch **sau** splash (`markSplashInactive → _maybeScheduleConsentDialog`). ⇒ **Ad splash hiển thị TRƯỚC khi user trả lời consent** — vi phạm "consent trước request đầu tiên" cho EEA.

## Acceptance criteria
- [ ] Trên splash, thứ tự bắt buộc: (iOS) ATT → UMP → chỉ khi `canRequestAds=true` mới `showAppOpenAd`.
- [ ] Nếu EEA và consent chưa resolved → **không** show splash app-open (điều hướng thẳng vào app, ad xuất hiện sau khi có consent).
- [ ] `loadAppOpenAd()` ở cuối `initialize` không tạo impression khi consent chưa cho phép (chỉ preload sau khi gate mở, hoặc preload nhưng chặn show).
- [ ] Cập nhật `packages/ad_sdk/README.md` mô tả thứ tự splash chuẩn.
- [ ] Host splash (`SplashScreen`) tuân theo hợp đồng mới (giữ hard-cap timer + `markSplashActive/Inactive`).

## Ghi chú kỹ thuật
- Phụ thuộc T01 (gate) + T07 (ATT). Tận dụng `AdScreenRouteLogger.isDialogOnTop` sẵn có để không chồng ad lên form.
- Cẩn thận không phá splash budget/hard-cap (CLAUDE.md: cancel hard-cap trước `showAppOpenAd`, `markSplashInactive` đúng 1 lần).

## Test
- [ ] Integration: EEA chưa consent → không có `AdShowEvent(appOpen)` trong splash.
- [ ] Integration: non-EEA → splash app-open vẫn hoạt động như cũ.
