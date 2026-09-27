# T223 — Fix thiếu watchdog và show timeout parity cho Rewarded Interstitial

- **Loại:** Fix (Defensive Hardening)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** ✅ done — REFUTED (already covered); chỉ bổ sung 1 regression test

## Vấn đề (Why) — theo ticket gốc
`AdMobAdapter.showRewardedInterstitial` và `AdManager.showRewardedInterstitialAd` bị cho là thiếu watchdog timer / stale-callback quarantine mà `showRewarded`/`showInterstitial` đã có, nên callback native bị drop sẽ khoá cờ hiển thị vĩnh viễn; và AppLovin (không có format này) phải fail-closed tại gate.

## Kết luận điều tra: ticket SAI — mọi cơ chế đã tồn tại

Bảng parity (đọc trực tiếp code, không suy đoán):

| Cơ chế | Interstitial | Rewarded | Rewarded Interstitial |
|---|---|---|---|
| Show-confirm watchdog (`AdSlot.beginShow(onShowNeverConfirmed:)`, 10s — `ad_slot.dart:345,375-400`) | `admob_adapter.dart:1308` | `admob_adapter.dart:1564` | `admob_adapter.dart:1818` ✅ |
| Cross-cycle late/stale callback guard (`cycleEnded`) | `admob_adapter.dart:1307,1330,1347` | `admob_adapter.dart:1546,1587,1631` | `admob_adapter.dart:1807,1839,1887` ✅ |
| Double-fire guard cho callback (`fired`/`fire()`) | `_interstitialDone` nulled tại `1313,1342,1360` | `admob_adapter.dart:1555-1562` | `admob_adapter.dart:1809-1816` ✅ |
| Adapter `show()` throw → slot released + onDone(false) | `admob_adapter.dart:1382-1391` | `admob_adapter.dart:1683-1690` | `admob_adapter.dart:1938-1948` ✅ |
| Fallback onDone khi timeout (watchdog gọi `fire(RewardResult.skipped)` rồi `markShowFailed()`) | `1308-1316` + `ad_slot.dart:397` | `1564-1570` | `1818-1824` ✅ |
| AdManager: `delivered` guard + try/catch quanh adapter call | `ad_manager.dart:7940-7977` | `ad_manager.dart:8394-8439` | `ad_manager.dart:8622-8671` ✅ |
| AppLovin fail-closed tại gate | n/a | n/a | `ad_manager.dart:8469-8475` (load) + `8532-8539` (show), reason `unsupported_provider`; adapter no-op `applovin_adapter.dart:2104-2112` không hề gọi `beginShow` nên slot không bao giờ rời `idle`, `canShowRewardedInterstitialAd()` (`ad_manager.dart:8677-8708`) trả `false` ✅ |

Nói ngắn: cả 4 acceptance criteria của ticket đã được đáp ứng từ trước (round-7, round-23, round-29, round-37, round-45/R45-03). Không thêm code sản phẩm — làm vậy sẽ là abstraction thừa.

## Bằng chứng test đã có sẵn

- `test/show_confirm_watchdog_test.dart:297` — `rewarded interstitial`: show bị nuốt → watchdog 10s nhả slot, `onDone` báo `earned:false`, ad được dispose.
- `test/admob_behavioral_test.dart:595` group `Rewarded Interstitial (T89)` — load ok/fail, earn→dismiss đúng 1 lần, dismiss không earn, show khi chưa có ad.
- `test/admob_behavioral_test.dart:809` — `MJ25 ... rewarded interstitial`: `show()` throw vẫn dispose ad và resolve caller.
- `test/ad_manager_core_test.dart:3193,3212,3231` — AppLovin: adapter no-op, và AdManager phát `reason=unsupported_provider` cho cả load lẫn show, resolve `shown:false, earned:false`.
- `test/r23_rewarded_interstitial_impression_test.dart` — impression tính theo `shown` chứ không theo `earned`; VIP/consent/cap gates giữ nguyên.
- `test/r23_rewarded_interstitial_disclosure_test.dart` — widget-level disclosure + huỷ không tốn ngân sách.
- `test/rewarded_kill_switch_gate_test.dart:74`, `test/ad_manager_core_test.dart:1333-1478` — `canShowRewardedInterstitialAd()` fail-closed theo dialog/overlay/stale.

## Khoảng trống duy nhất: test, không phải code

Group `round-29 audit (MAJOR): cross-cycle late callback` (`test/admob_behavioral_test.dart:968`) chỉ pin interstitial và rewarded — rewarded interstitial dùng đúng cơ chế đó nhưng chưa có test riêng. Đã bổ sung:

- `test/show_confirm_watchdog_test.dart` — `rewarded interstitial: late callbacks after the watchdog are ignored`: sau khi watchdog nhả slot, `onUserEarnedReward` + `onDismissed` + `onFailedToShow` muộn phải bị bỏ qua; `onDone` chạy đúng 1 lần, không có phần thưởng nhân đôi, slot ở `cooldown` (không bị late dismiss ghi đè thành `idle`).

## Acceptance Criteria

- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi (không đổi code sản phẩm — cơ chế đã có).
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Kiểm thử: unit test bổ sung ở trên; widget + integration cho format này đã có sẵn (xem danh sách bằng chứng) và không đổi hành vi nên không nhân bản thêm.
- [x] `flutter analyze` sạch 0 cảnh báo; `flutter test` 2309/2309 pass.
