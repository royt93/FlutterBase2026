# T245 — AdMob fullscreen: late/duplicate load result mid-show kicks the slot out of `showing`

- **Loại:** Fix
- **Priority:** P1 · **Severity:** MAJOR (độ tin cậy audit 80%)
- **Status:** inprogress (chờ audit độc lập sau fix, cần >9/10 mới push)

## Vấn đề

Tìm thấy ở audit round 76 (reviewer chỉ đọc, tôi tự đọc lại code để xác nhận).
`AdMobAdapter` App Open / Interstitial / Rewarded / RewardedInterstitial: `onLoaded` và
`onFailed` không kiểm tra `slot.isShowing`. Kịch bản: load L1 treo, watchdog đưa slot
vào cooldown, L2 bắt đầu, L1 về muộn và đưa slot sang `ready`, host show ad A, rồi L2
về. `markReady()` đẩy slot từ `showing` về `ready`, ghi đè `_xAd` (mất tham chiếu ad A)
và `requestId`.

Hậu quả (đã tái hiện bằng test):
- `_fullscreenBusyReason` đọc "không bận" trong khi ad A đang trên màn hình, nên có thể
  xếp chồng một fullscreen thứ hai.
- Sau khi A đóng, slot giữ một ad cũ trong cache mà không show được (chỉ App Open đã
  tái hiện đầy đủ ở test).
- Failure muộn khi `showing` làm slot rơi vào `cooldown`.

## Sửa

Mỗi `onLoaded`: nếu slot đang `showing` thì bỏ qua, và chỉ dispose ad bị từ chối khi nó
KHÔNG bọc chính ad native đang được giữ (so bằng `==` trên 4 wrapper bridge; `identical()`
lúc đầu vô hiệu vì bridge tạo wrapper mới ở mỗi callback, reviewer đã chỉ ra) (dispose ad đang hiển thị sẽ xoá content callback nên
dismiss không bao giờ tới). Mỗi `onFailed`: nếu slot đang `showing` thì bỏ qua.
Không dùng token theo từng lượt load (diff lớn hơn, `lib` chỉ còn ~20KB dư).

## Kiểm chứng

- Unit (`test/admob_behavioral_test.dart`, group "audit round 76"): success, failure,
  cùng ad giao lại, failure không phát AdLoadEvent / không tăng failure, dismiss thật
  vẫn resolve, mutex AdManager vẫn giữ — 4 format. Đỏ khi bỏ guard, xanh khi có.
- Widget (`test/admob_late_load_midshow_widget_test.dart`): nút host bind `fullscreenBusy`
  vẫn bị khoá, show thứ hai qua AdManager bị từ chối. Đỏ khi bỏ guard.
- Wrapper thật (`test/gma_bridge_test.dart`): hai callback `onAdLoaded` cho cùng adId qua codec
  của plugin cho hai wrapper bằng nhau, adId khác thì không. Đỏ khi bỏ `==`.
- Integration (`example/integration_test/admob_late_load_midshow_test.dart`): chạy lại bộ
  widget test trên Android thật (`2B051FDH3006MU`) và iOS Simulator, đều xanh. Đây là
  render và mutex AdManager thật với callback tiêm qua bridge giả; KHÔNG chứng minh
  Google Ads SDK native giao callback muộn, thứ không ép được.

## Giới hạn đã biết

- Guard theo trạng thái, không theo danh tính lượt load. Một fill muộn rơi vào lúc slot
  đang `loading`/`ready` vẫn ghi đè `_xAd` mà không dispose ad cũ (rò native), nhưng
  không có ad nào trên màn hình. Cùng lớp lỗi, chưa sửa.
- Chưa có bằng chứng plugin `google_mobile_ads` thật có giao callback muộn hay trùng.
- App Open dismiss callback chưa có danh tính theo lượt (reviewer: LOW, khó chạm tới
  vì `dispose()` null hoá callback native).
- Full suite có flake đã biết từ round 71: `r23_coppa_midinit_flip_test.dart` và
  `consent_fallback_wiring_test.dart` thỉnh thoảng đỏ khi chạy song song, xanh khi
  chạy riêng và khi `--concurrency=1`. Không liên quan thay đổi này (xem chạy 3 lần
  có/không có thay đổi).

## Audit

CHƯA CHẤM sau fix. Trước fix: round 76 cho 6.5/10.
