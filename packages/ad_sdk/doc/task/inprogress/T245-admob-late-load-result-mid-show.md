# T245 — AdMob fullscreen: late/duplicate load result mid-show kicks the slot out of `showing`

- **Loại:** Fix
- **Priority:** P1 · **Severity:** MAJOR (độ tin cậy audit 80%)
- **Status:** inprogress (điểm cuối 8.5/10 chưa vượt ngưỡng >9; chờ quyết định của chủ dự án)

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
dismiss không bao giờ tới). Mỗi `onFailed`: bỏ qua nếu slot đang `showing` hoặc `ready` (vòng 6 tìm ra nhánh `ready`). Khối `catch` của
4 hàm load (platform call ném lỗi) cũng thoát sớm khi slot đang `showing` hoặc `ready` (vòng 5 tìm ra
nhánh `showing`, vòng 6 nhánh `ready`); mỗi nhánh tôi tái hiện bằng test đỏ rồi mới sửa.
Không dùng token theo từng lượt load (diff lớn hơn, `lib` chỉ còn ~20KB dư).

## Kiểm chứng

- Unit (`test/admob_behavioral_test.dart`, group "audit round 76"): success, failure,
  cùng ad giao lại, failure không phát AdLoadEvent / không tăng failure, dismiss thật
  vẫn resolve, mutex AdManager vẫn giữ — 4 format. Đỏ khi bỏ guard, xanh khi có.
- Widget (`test/admob_late_load_midshow_widget_test.dart`): nút host bind `fullscreenBusy`
  vẫn bị khoá, show thứ hai qua AdManager bị từ chối. Đỏ khi bỏ guard.
- Catch path (`B throws after A's late fill was shown`, 4 format): request B treo, fill muộn của
  A hạ cánh và được show, rồi platform call của B ném lỗi. Đỏ trên code cũ, xanh sau guard, đỏ
  lại khi bỏ riêng guard của catch.
- Wrapper thật (`test/gma_bridge_test.dart`): hai callback `onAdLoaded` cho cùng adId qua codec
  của plugin cho hai wrapper bằng nhau, adId khác thì không. Đỏ khi bỏ `==`.
- Integration (`example/integration_test/admob_late_load_midshow_test.dart`): chỉ chạy lại file
  widget test (KHÔNG gồm các test `catch` nằm ở `admob_behavioral_test.dart`) trên Android thật (`2B051FDH3006MU`) và iOS Simulator, đều xanh. Đây là
  render và mutex AdManager thật với callback tiêm qua bridge giả; KHÔNG chứng minh
  Google Ads SDK native giao callback muộn, thứ không ép được.

## Giới hạn đã biết

- ~~Guard của `catch` chỉ phủ `showing`~~ ĐÃ ĐÓNG: guard giờ phủ cả `showing` lẫn `ready`, nên một fill muộn đã load (chưa show) không bị vứt khi platform call của request khác ném lỗi. Hai chiều đều có test: bỏ `ready` khỏi guard thì test `ready` đỏ, và guard nuốt hết thì test lỗi bình thường (slot chỉ `loading`) đỏ.
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

Sáu vòng reviewer chỉ đọc, phạm vi hẹp (diff này và các đường code đã truy vết, không chứng minh cho cả repo). Điểm phần AdMob, đúng thứ tự đã nhận:
1. Round 76 (trước fix): 6.5/10. Finding MAJOR chính là lỗi này.
2. Sau guard `isShowing`: 8/10. `identical()` trên wrapper vô hiệu ở máy thật; test widget thứ ba pass vì lý do yếu.
3. Sau khi so wrapper theo ad native: 9/10. Thiếu test gộp equal-but-not-identical.
4. Sau test gộp: 9/10.
5. Vòng 5: 8.5/10. `catch` của hàm load chưa có guard (kịch bản `showing`).
6. Vòng 6: 8.5/10. Nêu hai điểm: `catch` còn nhánh `ready`, và `onFailed` khi slot `ready` (phổ biến hơn `catch`).

Cả hai đã tái hiện bằng test đỏ rồi sửa; mutation check hai chiều xác nhận guard không thừa cũng không nuốt lỗi bình thường. Sau các sửa này CHƯA có vòng chấm lại. Điểm cuối ghi nhận là 8.5/10, dưới ngưỡng >9, nên task CHƯA đóng.

Xu hướng: mỗi vòng reviewer mới tìm thêm một đường cùng lớp, điểm dao động 8.5–9 và chưa vượt 9. Đây là tín hiệu của lớp lỗi "callback muộn không gắn với lượt load", mà guard theo trạng thái chỉ vá từng đường; bản sửa gốc là gắn token theo từng lượt load, đã cân nhắc và hoãn vì diff lớn và `lib` chỉ còn khoảng 20KB trước trần gate.
