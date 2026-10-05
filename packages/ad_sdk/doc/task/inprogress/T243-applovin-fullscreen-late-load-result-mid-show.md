# T243 — AppLovin fullscreen: late load result mid-show kicks the slot out of `showing`

- **Loại:** Fix
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** inprogress (chờ audit độc lập sau fix)

## Bối cảnh & Vấn đề

Tìm thấy ở audit round 75 (reviewer độc lập, đã tự xác minh bằng code + probe).
`AppLovinAdapter` App Open/Interstitial/Rewarded: `onAdLoaded`/`onAdLoadFailed`
không kiểm tra `slot.isShowing`. Một load muộn hoặc trùng (load treo -> watchdog
retry -> cả hai cùng về) rơi vào giữa lúc đang show sẽ gọi `markReady()` /
`markFailed()`, đẩy slot ra khỏi `showing` (probe: `showing=false`,
`state=cooldown` sau load-failed). Watchdog App Open yêu cầu `isShowing` nên tự
thoát im lặng; nếu `onAdHidden` thật cũng mất thì caller (splash) treo.

## Sửa

Bỏ qua kết quả load (thành công và thất bại) khi slot đang `showing`, cho cả 3
format. Không đổi AdMob. Sửa thêm comment hard cap: thực tế ~95s (tick thứ 19),
không phải 90s; KHÔNG đổi thời gian.

## Acceptance Criteria

- [x] Unit: load-success mid-show giữ `showing` (App Open, Interstitial, Rewarded).
- [x] Unit: App Open watchdog vẫn resolve sau load muộn.
- [x] Unit: load-failure mid-show giữ `showing` cho cả 3 format.
- [x] Widget: splash vẫn thoát qua watchdog sau load-success/load-failure muộn.
- [x] Mutation check: bỏ guard thì test đỏ, có guard thì xanh.
- [x] `flutter analyze` sạch; full `flutter test` pass; release gate pass.
- [ ] Audit độc lập sau fix, điểm >9/10.
- [x] Integration sau fix cuối: Android thật (device `2B051FDH3006MU`) pass 2/2, iOS Simulator pass 2/2 (chờ hard cap thật). Đây là test điều khiển adapter qua bridge ghi lại, không phải smoke test quảng cáo AppLovin thật.
- [x] Full flutter test sau fix cuối: pass (2499 test).
- [ ] Giới hạn: gate size `lib` đang đúng ngưỡng 2048KB, thêm code sau này sẽ chạm trần.

## Audit Score

9/10 (phạm vi hẹp, reviewer độc lập chỉ đọc). Không có finding chặn. Thiếu 1 test hồi quy creativeId-clobber: ĐÃ bổ sung (mutation check đỏ/xanh). Điểm 9/10 CHƯA vượt ngưỡng >9, nên chưa push. Còn ghi nhận: nhánh drop không phát AdLoadEvent (chấp nhận được), load muộn rơi vào `idle`/`cooldown` chưa được guard (đã có từ trước, ngoài phạm vi).