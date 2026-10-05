# T246 — Per-request load token for AdMob fullscreen loads (DESIGN, not implemented)

- **Loại:** Design / Hardening
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** todo — chờ chủ dự án duyệt phương án. KHÔNG có code nào được viết cho task này.

## Vì sao có task này

T245 vá lớp lỗi "kết quả load đến muộn không gắn với lượt load nào" bằng guard theo
TRẠNG THÁI của slot. Sáu vòng audit chỉ đọc, mỗi vòng tìm thêm một đường cùng lớp
(`onLoaded` khi showing → `onFailed` khi showing → `catch` khi showing → `catch` khi
ready → `onFailed` khi ready). Điểm dao động 8.5–9/10 và chưa vượt 9. Guard theo trạng
thái chỉ vá được từng đường đã biết.

Một guard theo trạng thái KHÔNG phân biệt được hai lượt load khi slot đang `loading`.
Đây là giới hạn đã ghi nhận ở T245: một fill muộn rơi vào lúc slot đang `loading` vẫn ghi
đè `_xAd` mà không dispose ad cũ (rò native object), và vẫn có thể chiếm chỗ của lượt
load hiện tại.

## Phương án

Gán một số thứ tự cho MỖI lần `load*()` thực sự bắt đầu, và mọi callback của lần đó
chỉ được tác động lên slot nếu số của nó còn là số HIỆN TẠI.

1. Mỗi adapter có một bộ đếm riêng cho mỗi format (đã có `_requestSeq` dùng cho
   `requestId`, nhưng nó chỉ tăng lúc fill hạ cánh; token mới phải tăng lúc `beginLoad`
   thành công).
2. `load*()`: sau khi `slot.beginLoad()` thành công, `final token = ++_xLoadSeq;` và đóng
   gói `token` vào `onLoaded`, `onFailed` và `catch`.
3. Mỗi callback: `if (token != _xLoadSeq) { dispose ad nếu có; return; }` thay cho TOÀN BỘ
   guard `isShowing`/`isReady` hiện có ở `onLoaded`, `onFailed` và `catch`.
4. `markShowFailed`/`markDismissed`/`reset()` (dismiss, expiry, consent) tăng token để
   mọi load còn bay bị coi là cũ.

Điểm cần quyết định: `isShowing || isReady` hiện tại KHÔNG tương đương `token != hiện tại`.
Token an toàn hơn ở chỗ nó cũng chặn được fill muộn khi slot `loading`; nhưng nó đổi
ngữ nghĩa của một load hợp lệ bị `reset()` giữa chừng (consent đổi) và cần thử lại.

## Cái giá

- **Dung lượng:** `lib` đo 2028 KB trên trần 2048 KB (gate T244 đo theo block 4 KB). Phương
  án thêm khoảng 4 trường đếm, 4 biến cục bộ, vài chục dòng; nhưng việc XOÁ guard cũ bù
  lại một phần. Chưa đo, không được hứa là vừa. Cần đo thật trước khi chọn.
- **Phạm vi:** đụng 4 hàm `load*`, 4 `onLoaded`, 4 `onFailed`, 4 `catch`, và các đường
  `reset`/`markDismissed`. Rủi ro hồi quy cao hơn một guard 1 dòng.
- **Test:** toàn bộ bộ test round 76 (đỏ khi bỏ guard) phải chuyển thành đỏ khi bỏ token,
  cộng thêm các ca mà guard trạng thái không bắt được: fill muộn khi `loading`, hai load
  chồng nhau, `reset()` giữa chừng.
- **Không phải API công khai:** `AdSlot` được export, nhưng token nằm trong adapter,
  không đổi bề mặt công khai (cần chạy lại `api_golden_test`).

## Không nằm trong phạm vi

- AppLovin: đã dùng `creativeId` làm tín hiệu cũ/mới và có quarantine; không đụng.
- Banner/MREC/Native: có cơ chế theo-từng-widget riêng.
- Chứng minh Google Ads SDK native giao callback muộn: không thể ép trên máy thật.

## Các lựa chọn cho chủ dự án

A. Làm token đầy đủ (thay guard trạng thái). Xử lý tận gốc; tốn dung lượng và rủi ro.
B. Giữ guard trạng thái hiện có, chấp nhận giới hạn "fill muộn khi `loading`". Không đụng
   code; lớp lỗi còn một đường hẹp đã ghi nhận.
C. Token chỉ cho riêng `onLoaded` khi `loading` (hẹp hơn A), giữ các guard còn lại.

## Tiêu chí hoàn thành (nếu chọn A hoặc C)

Viết test đỏ cho từng ca TRƯỚC khi sửa; mutation check hai chiều; unit + widget + integration
chạy được trên Android và iOS; audit độc lập >9/10; smoke trên thiết bị; chỉ khi đó push.

## Dữ kiện đã đọc từ code (để ước lượng phạm vi, không phải bằng chứng cho thiết kế)

- `AdMobAdapter` có 4 hàm `load*` (App Open, Interstitial, Rewarded, RewardedInterstitial).
- `_requestSeq`/`_nextRequestId()` chỉ được gọi trong `onLoaded` (4 chỗ), tức sau khi fill hạ cánh.
- 9 chỗ gọi `markDismissed()` và 13 chỗ gọi `markShowFailed()` sẽ cần quyết định có tăng token hay không.
- `slot.reset()` xuất hiện ở `dispose()` và `discardCachedFullscreenAds()`.
- Adapter AdMob không dùng `beginReload` cho 4 format fullscreen.
- `AdManager` arm watchdog load 30s cho mỗi format; token phải phối hợp với watchdog này, vì
  watchdog buộc slot vào cooldown rồi một lượt load mới có thể bắt đầu trong khi lượt cũ còn bay.
