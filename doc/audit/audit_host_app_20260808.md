# Audit host app FastNet (`saigonphantomlabs`) — WiFi stressor, VIP wiring, persistence, native channel, code health (2026-08-08)

**Người audit:** Claude (Sonnet 5), đọc source trực tiếp.
**Phạm vi:** app host trong repo này (`lib/mckimquyen/`), KHÔNG phải `packages/ad_sdk/` — 11 audit doc trước đó (`audit_claude_20260802.md` và các doc cũ hơn) đều nhắm vào SDK hoặc SDK+host integration. Đây là audit đầu tiên nhắm riêng vào host app.
**Nguyên tắc:** mọi finding dưới đây đã mở source xác minh tới từng dòng, trích `file:line` cụ thể. Không có finding nào được liệt kê chỉ để lấp đầy mục — phần nào sạch thì ghi rõ là sạch.

## 0. Kết luận theo từng hạng mục

| # | Hạng mục | Đánh giá |
|---|---|---|
| 1 | Stressor core: an toàn endpoint + dọn timer mọi teardown path | **Một phần** — dọn timer đúng ở mọi path (kể cả `_thermalTimer` mới thêm), nhưng **H1** 500 parallel × không giới hạn thời lượng mặc định là rủi ro tải bền vững |
| 2 | VIP grace-nudge listener race (giả thuyết: hard-cap 8s bắn trước `initRevision` → listener không bao giờ attach) | **Giả thuyết bị bác bỏ** — có cơ chế retry đúng, xem mục 2 |
| 3 | Ad-key fallback (AdMob test ID trong khi AppLovin active) | **Đã fix** — Workstream D đã ship ID AdMob thật + đổi provider active |
| 4 | Hive/SharedPreferences persistence, concurrent-save race | **Một phần** — **H4** race nhỏ ở `_cleanupOldResults()`, **H5** `SharedPreferencesUtil` thiếu `await` + `resetAllData()` chết code |
| 5 | Native channel error handling (Android MethodChannel ↔ Dart) | **Đạt** — mọi call site try/catch, degrade `null` sạch trên iOS |
| 6 | Code health sweep (`late`/`!`/`setState`/`Get.snack`) | **Một phần** — `ui_utils.dart`/`formatter/` sạch hoàn toàn; **H6** 4 chỗ `!` trong `ext/zoom_inkwell.dart`, 1 chỗ unguarded |

---

## 1. MEDIUM — H1: không có trần thời lượng/tải mặc định cho stress test

`lib/mckimquyen/widget/wifi_stressor/stressor_controller.dart`:

- `parallelDownloads` mặc định 50 (`:22`), UI cho chọn tới **500** (`widgets/control_panel_widget.dart:57`: `const connectionOptions = [1, 5, 10, 15, 30, 50, 100, 200, 500]`).
- `selectedDurationSec` mặc định `null` = "không giới hạn, dừng thủ công" (`:25` comment). Không có preset "unlimited" nào bị chặn ở tầng UI/controller.
- `_runDownloadLoop` (`:695-889`) là vòng lặp `while (isRunning.value)` không giới hạn số lần lặp, delay cố định 100ms giữa các lần request kể cả sau lỗi (`:883`; trường hợp lỗi liên tục cũng chỉ delay thêm 100ms ở `:784` trước khi `continue`).
- Danh sách 26 URL (`:72-116`) đều là CDN/speed-test endpoint công khai hợp lệ cho mục đích này (Cloudflare `speed.cloudflare.com/__down`, Linode/Vultr/OVH/ThinkBroadband speed-test binaries, GitHub release asset, Cachefly) — không phải hammering site tuỳ ý. Không có vấn đề "target sai loại endpoint".
- Không có backoff luỹ tiến khi 1 URL liên tục lỗi trong ngưỡng cho phép (`_urlErrorCount >= 3` mới quarantine 2 phút, `:776-786`, `:870-880`) — trong 3 lần lỗi đầu, retry vẫn diễn ra mỗi 100ms.

**Hệ quả:** 500 loop song song × không giới hạn thời gian là cấu hình hợp lệ user có thể tự chọn, và sẽ giữ tải mạng + pin + nhiệt liên tục vô thời hạn cho tới khi user bấm Stop. Đây chính là lý do tính năng "thermal throttle detector" (2026-08-08) được thêm — bản thân team đã nhận ra rủi ro nhiệt. Nhưng chưa có cơ chế nào tự động hạ tải hoặc cảnh báo khi test chạy quá lâu ở mức song song cao (badge thermal chỉ hiển thị SAU khi lưu kết quả, không phản hồi real-time để tự dừng).

**Không phải bug** — đây là tính năng cố ý ("stress" tester theo đúng tên), nhưng đáng để cân nhắc: cảnh báo mềm khi user chọn 200+/500 kết nối VÀ không đặt duration preset (kết hợp 2 điều kiện rủi ro nhất).

**Đề xuất:** cân nhắc soft-warning trong dialog xác nhận (`:252-296`) khi `parallelDownloads >= 200 && selectedDurationSec == null`, hoặc auto-suggest bật thermal polling sớm hơn ngưỡng 60s hiện tại (`_thermalPollMinDurationSec`, `:129`) cho cấu hình tải cao. Không block — chỉ nudge.

### Dọn timer — xác nhận sạch

Cả 5 timer (`_updateTimer`, `_retryTimer`, `_latencyTimer`, `_uploadTimer`, `_thermalTimer`) được khai báo `:120-124` và cancel đầy đủ ở **cả hai** teardown path:

- `stopStressTest()` (`:450-479`): cancel cả 5 ở `:466-470`.
- `_cleanup()` (`:232-244`, gọi từ `onClose()` ở `:226`/`:223-224`): cancel cả 5 ở `:234-238`, cộng thêm `_latencyService.close()`, `_uploadService.close()`, `dio.close()` (`:239-243`) — không leak Dio client.
- Trường hợp app bị dispose bất thường giữa lúc đang chạy (`onClose()` khi `isRunning.value == true`, `:203-227`): code lưu kết quả `'interrupted'` trước (fire-and-forget qua `.catchError`, `:218-220`), rồi `Future.delayed(100ms)` gọi `_cleanup()` (`:222-224`) — timer vẫn được cancel, chỉ trễ 100ms chứ không leak vĩnh viễn.
- `_thermalTimer` (thêm 2026-08-08) đúng convention: khai báo `:124`, start có điều kiện `:363-368` (chỉ khi `durationSec == null || durationSec >= 60`), cancel ở cả 2 nơi `:238`/`:470`. Không phát hiện leak.

Không tìm thấy timer/Dio client nào bị bỏ sót trên bất kỳ exit path nào đã kiểm tra.

---

## 2. Giả thuyết VIP grace-nudge listener race — BÁC BỎ

`lib/mckimquyen/widget/wifi_stressor/wifi_stressor_screen.dart:64-82` (`_StressorHomePageState.initState()`):

```dart
_attachGraceNudgeListener();          // :76 — thử attach ngay, vip có thể null
_attachFirstInstallGrantListener();   // :77
AdManager().initRevision.addListener(_attachGraceNudgeListener);        // :80
AdManager().initRevision.addListener(_attachFirstInstallGrantListener); // :81
```

Giả thuyết cần kiểm: nếu splash's hard-cap 8s (`lib/mckimquyen/widget/splash/splash_screen.dart:69`, `Timer(const Duration(seconds: 8), ...)`) bắn TRƯỚC khi SDK init xong (adapter init có timeout riêng 20s, `packages/ad_sdk/lib/src/core/ad_manager.dart:1295`), thì `_navigateToMainSafely()` đưa user sang `StressorHomePage` trong lúc `AdManager().vip` vẫn còn `null` — `_attachGraceNudgeListener()` ở dòng 76 sẽ no-op (vì `AdManager().vip?.graceNudgeDueListenable` là `null`). Câu hỏi: có retry khi SDK init xong sau đó không?

**Có, và đúng.** Chuỗi xác minh:

1. `_vipManager = vip` được gán ở `ad_manager.dart:1089`, **trước** `initRevision.value = initRevision.value + 1` ở `ad_manager.dart:1310` — cùng trong `initialize()`. Tức là khi `initRevision` bump, `AdManager().vip` đã chắc chắn non-null.
2. `wifi_stressor_screen.dart:80-81` đăng ký `_attachGraceNudgeListener`/`_attachFirstInstallGrantListener` làm listener của `initRevision` **vô điều kiện** trong `initState()` — không phụ thuộc kết quả gọi trực tiếp ở dòng 76/77 thành công hay không.
3. Toàn bộ khối `:76-81` chạy đồng bộ (không có `await` xen giữa) trong cùng 1 frame của `initState()` — Dart single-threaded nên không có race window giữa lần gọi trực tiếp và lúc đăng ký listener.
4. Do đó: nếu init hoàn tất SAU khi màn hình này đã mount (đúng kịch bản giả thuyết nêu), `initRevision` bump sẽ trigger `_attachGraceNudgeListener()` lần nữa qua listener đã đăng ký sẵn, lúc này `AdManager().vip` đã có giá trị → attach thành công.
5. `_attachGraceNudgeListener()` tự thân idempotent đúng cách (`identical(current, _attachedGraceNudgeListenable) return`, `:93`) — gọi lại nhiều lần không double-attach.

**Kết luận:** không có gap. Cơ chế "gọi trực tiếp 1 lần + đăng ký lại qua `initRevision` listener" chính là bounded retry đang hoạt động đúng thiết kế — không cần sửa gì thêm. Giả thuyết ban đầu (không có retry) sai vì đã bỏ sót việc `initRevision.addListener` luôn được đăng ký bất kể lần gọi đầu có thành công hay không.

---

## 3. RESOLVED — Ad-key fallback (AdMob test ID trong khi AppLovin active)

Finding cũ từ phiên trước: `AdKey.adMob` giữ Google test unit ID trong khi provider active là AppLovin — gây nhầm lẫn/nguy cơ lỡ ship test ID.

**Đã fix (Workstream D, 2026-08-08):**
- `lib/mckimquyen/common/const/ad_keys.dart:51-56` — `AdKey.adMob` giờ chứa unit ID production thật: `ca-app-pub-3004713799155145/1405549185` (banner), `.../4527938918` (interstitial), `.../6079291367` (appOpen), `.../8709324135` (rewarded) — khác hẳn dải test công khai `ca-app-pub-3940256099942544/...` của Google.
- `lib/mckimquyen/widget/splash/splash_screen.dart:229` — `provider: AdProvider.admob` (đã đổi từ `AdProvider.appLovin`).
- Doc-comment ở `ad_keys.dart:5-13` đã cập nhật đúng thực tế mới (AdMob là active, AppLovin là "fallback/swap-ready"), không còn `TODO(host-app)` treo.

Không cần re-investigate sâu — 1 dòng xác nhận là đủ theo yêu cầu phạm vi.

---

## 4. Hive/SharedPreferences persistence

### 4a. MEDIUM — H4: race nhỏ ở `_cleanupOldResults()` khi 2 save chồng nhau

`lib/mckimquyen/widget/wifi_stressor/services/test_history_storage.dart:78-92`:

```dart
Future<void> saveTestResult(TestResult result) async {
  ...
  await _box?.put(result.id, result);
  await _cleanupOldResults();   // :88
}
```

`_cleanupOldResults()` (`:200-215`) tự đọc `getAllResults()` (snapshot toàn bộ box), so sánh với `_maxHistoryItems = 100` (`:12`), rồi xoá phần thừa — không có lock/mutex nào bảo vệ đoạn đọc-rồi-xoá này.

**Kịch bản race cụ thể trong repo:** `stressor_controller.dart:218` gọi `_saveTestResult('interrupted')` **fire-and-forget** (`.catchError`, không `await`) trong `onClose()`, ngay sau đó lên lịch `_cleanup()` qua `Future.delayed(100ms)` (`:222-224`). Nếu user thao tác đủ nhanh để khởi động lại 1 test mới trên controller instance mới (`Get.put(StressorController())` tạo instance mới) trong khoảng 100ms đó, `_saveTestResult` của instance cũ và instance mới đều gọi vào cùng 1 singleton `_storage` (`TestHistoryStorage.instance`, `:133`), có thể cả hai đang thực thi `_cleanupOldResults()` gần như đồng thời.

Vì Hive `Box` operations chạy tuần tự trên cùng isolate (không phải multi-thread thật), sẽ **không có data corruption** — nhưng 2 lệnh gọi `getAllResults()` liên tiếp có thể đọc cùng 1 snapshot trước khi lệnh xoá đầu tiên commit, dẫn đến tính sai `itemsToDelete` (`:210`) và xoá dư/thiếu vài item so với trần 100. Hậu quả tối đa là lệch giới hạn retention vài bản ghi — **không mất toàn bộ lịch sử, không crash**.

`updateRoomTag()` (`:557-565`) cũng gọi `_storage.saveTestResult()` (ghi đè cùng `id`, không tạo record mới — Hive `put` là idempotent theo key) nên không cộng thêm rủi ro tăng số lượng, chỉ cộng thêm 1 lần `_cleanupOldResults()` chạy dư nếu trùng thời điểm với 1 save khác.

**Đề xuất:** bọc `saveTestResult()` bằng 1 `Completer`/lock đơn giản (hoặc gộp cleanup vào 1 lần mỗi N lần save thay vì mỗi lần) nếu muốn triệt để — mức độ hiện tại là MEDIUM vì hệ quả chỉ là lệch retention, không mất/hỏng dữ liệu chính.

### 4b. LOW — H5: `SharedPreferencesUtil` thiếu `await` trên write + dead code

`lib/mckimquyen/util/shared_preferences_util.dart`:

- `:47-49` `setInt()`, `:57-59` `setBool()`, `:67-69` `setString()`: cả 3 hàm `await SharedPreferences.getInstance()` nhưng **không** `await` lệnh `prefs.setX(...)` phía sau (thiếu `await` trước `prefs.setInt(key, value);` ở `:49` — tương tự `:59`, `:69`). Hàm trả về `Future<void>` nhưng future đó resolve trước khi write thực sự flush xong. Nếu caller đọc lại giá trị ngay sau khi `await setInt(...)` mà không có delay, có rủi ro đọc giá trị cũ (native SharedPreferences write là async trên cả Android/iOS).
- `:25` `resetAllData()` khai báo `static void resetAllData() async` — trả về `void` chứ không phải `Future<void>`, nghĩa là caller **không thể `await`** hàm này dù bên trong nó có 2 lần `await` (`:28-34`) trước khi `prefs.clear()` (`:36`). Đây là anti-pattern kinh điển ("fire-and-forget async void").
- Xác minh: `resetAllData()` hiện **không được gọi ở đâu trong `lib/`** (`grep -rn "resetAllData" lib/` chỉ khớp chính định nghĩa của nó) — là dead code, nên rủi ro thực tế bằng 0 cho tới khi ai đó gọi lại.

**Mức độ:** LOW — `setInt`/`setBool`/`setString` thiếu `await` là latent bug ảnh hưởng bất kỳ call site tương lai nào cần đọc-ngay-sau-khi-ghi, nhưng các call site hiện tại (`getOrCreateSsvUserId` ở `:15-23`, dùng nội bộ chờ qua await của chính hàm) không bị lộ triệu chứng vì không có tình huống đọc lại tức thời. `resetAllData()` là dead code, an toàn để xoá hoặc sửa `Future<void>` nếu định dùng lại.

---

## 5. Native channel error handling — sạch

`android/app/src/main/kotlin/com/saigonphantomlabs/base/MainActivity.kt:30-41` khai báo `MethodChannel` `"com.saigonphantomlabs.base/wifi"` với 4 method: `getRssi`, `getWifiInfo`, `getNetworkDetails`, `getThermalStatus`. Cả 4 handler Kotlin (`currentRssi():45-56`, `currentWifiInfo():59-79`, `currentNetworkDetails():86-104`, `currentThermalStatus():113-122`) đều bọc `try/catch (e: Exception)` trả `null`/`emptyMap()`, không throw ra ngoài `setMethodCallHandler`. `currentThermalStatus()` guard thêm `Build.VERSION.SDK_INT < Build.VERSION_CODES.Q` trước khi gọi `PowerManager.getCurrentThermalStatus()` (`:114`), đúng pattern try/catch-safe-default như `currentNetworkDetails()`.

Phía Dart, `lib/mckimquyen/widget/wifi_stressor/services/network_info_service.dart` — **không có handler nào trên iOS** cho kênh này (đúng như kỳ vọng, MethodChannel này chỉ khai báo phía Android), và mọi call site Dart bọc try/catch riêng:

- `getSignalStrength()` (`:24-33`) — catch → `null`.
- `getWifiInfoMap()` (`:37-44`) — catch → `null`.
- `getNetworkDetailsMap()` (`:69-77`) — catch → `null`.
- `getThermalStatus()` (`:81-88`, mới thêm cho tính năng thermal) — catch → `null`, đúng pattern y hệt 3 hàm còn lại (`SafeLogger.d('Log', 'getThermalStatus failed (likely non-Android): $e')`).

Trên iOS, `invokeMethod`/`invokeMapMethod` gọi vào 1 channel không có native handler sẽ ném `MissingPluginException` — đúng dự đoán trong plan, và được catch gọn gàng, không throw lên UI, không hang. Không phát hiện call site nào thiếu try/catch hoặc có khả năng crash/hang trên iOS.

**Không có finding** cho mục này.

---

## 6. Code health sweep

### `lib/mckimquyen/util/ui_utils.dart` (1000 dòng)

Grep `\blate\b`, force-null `!`, `setState`, `Get.snack` trên toàn file: **0 match cho cả 4**. File hoàn toàn static-method class (`class UIUtils { static ... }`), không có state riêng nên không áp dụng `setState`/`late` theo bản chất, và không có `!` nào. Sạch.

### `lib/mckimquyen/formatter/date_text_formatter.dart`

37 dòng, `DateTextFormatter extends TextInputFormatter`, thuần logic string/index không dùng `late`/`!`/`setState`/`Get.snack`. Sạch.

### `lib/mckimquyen/ext/router.dart`

13 dòng, hàm `backScreen()` dùng `Get.context` + null-check tường minh (`if (c == null) return;`) — không force-null. Sạch.

### LOW — H6: `lib/mckimquyen/ext/zoom_inkwell.dart` — 4 chỗ dùng `!`, 1 chỗ unguarded

- `:11` — `extension ZoomEffect on InkWell { InkWell zoomOnTap() { ... child: _ZoomAnimation(onTap: onTap, child: child!) ... } }`. `InkWell.child` (kế thừa từ `InkResponse`) là `Widget?` trong Flutter SDK — force-null này **không được guard** bởi bất kỳ null-check nào trong hàm. Call site hiện tại duy nhất (`lib/mckimquyen/common/circle_button.dart:49`) luôn truyền `child`, nên chưa crash trong thực tế, nhưng là landmine: bất kỳ `InkWell` nào gọi `.zoomOnTap()` mà không có `child` sẽ throw ngay.
- `:43` — `_scaleAnimation = Tween<double>(...).animate(_controller!)`. Có guard `if (_controller == null) { //do nothing } else { ... }` ngay phía trên (`:40-44`) — về logic an toàn (chỉ chạy nhánh `else` khi `_controller != null`), nhưng vẫn dùng `!` thay vì đơn giản là gán trực tiếp trong nhánh `else` (verbose + vẫn vi phạm quy ước "không dùng `!`" dù runtime an toàn).
- `:54` — `widget.onTap!()`, guard bởi `if (widget.onTap != null)` ngay phía trên (`:50-55`) — an toàn tại runtime, vẫn vi phạm quy ước literal.
- `:78` — `animation: _scaleAnimation!` trong `AnimatedBuilder`, guard bởi early-return `if (_scaleAnimation == null) return const SizedBox.shrink();` ở đầu `build()` (`:72-74`) — an toàn tại runtime, vẫn vi phạm quy ước literal.

3/4 chỗ (`:43`, `:54`, `:78`) an toàn tại runtime nhờ guard liền kề nhưng đều là `!` theo nghĩa đen mà `doc/init.md` yêu cầu tránh — có thể thay bằng `?.`/gán trực tiếp trong nhánh đã null-check để tuân thủ đúng quy ước không cần đổi hành vi. Riêng `:11` là **thực sự unguarded** — mức rủi ro cao hơn 3 chỗ còn lại dù cùng file.

Không tìm thấy `setState`/`late` trong file này (dòng 16 chỉ là comment nhắc "without setState", animation dùng `AnimationController`/`AnimatedBuilder` đúng pattern reactive).

### `Get.snack` — sạch toàn repo

`grep -rn "Get\.snack" lib/` không có kết quả nào trong toàn bộ `lib/` — không tìm thấy vi phạm quy ước "dùng `AppSnackbar`, không dùng `Get.snack`".

---

## 7. Bảng tổng hợp finding

| ID | Mức độ | Mô tả ngắn | File:line |
|---|---|---|---|
| H1 | Medium | 500 parallel × unlimited duration, không cảnh báo tải bền vững | `stressor_controller.dart:22`, `control_panel_widget.dart:57`, `:25` |
| H2 | — | Giả thuyết VIP grace-nudge race — **bác bỏ**, retry hoạt động đúng | `wifi_stressor_screen.dart:76-81`, `ad_manager.dart:1089,1310` |
| H3 | — | Ad-key fallback — **đã fix** (Workstream D) | `ad_keys.dart:51-56`, `splash_screen.dart:229` |
| H4 | Medium | Race nhỏ ở `_cleanupOldResults()` khi 2 save chồng nhau | `test_history_storage.dart:78-92,200-215` |
| H5 | Low | `SharedPreferencesUtil` write thiếu `await`; `resetAllData()` là dead code, kiểu `void async` | `shared_preferences_util.dart:25,47-49,57-59,67-69` |
| H6 | Low | 4 chỗ `!` trong `zoom_inkwell.dart`, 1 chỗ (`:11`) thực sự unguarded | `zoom_inkwell.dart:11,43,54,78` |

Không phát hiện finding nào ở mức Critical/High. Native channel handling (mục 5) và phần lớn code-health sweep (mục 6, trừ 1 file nhỏ) hoàn toàn sạch.

---

## 8. Verdict tổng thể

**Host app ở trạng thái tốt, không có blocker production.** Không tìm thấy Critical/High. Toàn bộ 6 hạng mục scope:

- Timer/Dio cleanup trên stressor core **đúng ở mọi teardown path** đã kiểm tra, kể cả timer mới thêm (`_thermalTimer`).
- Giả thuyết race nghiêm trọng nhất trong scope (VIP grace-nudge listener) **bị bác bỏ sau khi đọc code** — cơ chế retry qua `initRevision` listener hoạt động đúng thiết kế, không cần sửa.
- Ad-key fallback finding cũ đã fix xong, xác nhận bằng ID thật trong code.
- Native channel (Android↔Dart, và độ suy biến sạch trên iOS) không có finding nào.
- 2 finding Medium (H1, H4) là rủi ro vận hành nhẹ (tải bền vững không cảnh báo; lệch nhẹ retention cap khi race hiếm gặp) — không gây mất dữ liệu, không crash.
- 2 finding Low (H5, H6) là vi phạm quy ước code-style cục bộ trong 2 file nhỏ (`shared_preferences_util.dart`, `zoom_inkwell.dart`) — dễ sửa, không ảnh hưởng hành vi hiện tại ngoại trừ 1 landmine thực sự unguarded (H6 dòng 11).

**Điểm số:** 8.5/10 — production-ready, không cần block release vì bất kỳ finding nào ở đây. Khuyến nghị dọn H5/H6 (rẻ, nhanh) trong lần chạm code kế tiếp tới các file đó; H1/H4 có thể để backlog vì mức ảnh hưởng thấp và không cấp thiết.
