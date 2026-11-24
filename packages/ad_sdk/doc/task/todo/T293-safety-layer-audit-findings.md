# T293 — Phát hiện từ audit lớp safety (cap / throttle / vi phạm), chờ quyết định

- **Loại:** Hardening / quyết định sản phẩm
- **Priority:** P2 · **Severity:** MEDIUM (chạm bảo vệ tài khoản AdMob và doanh thu)
- **Status:** todo — điểm 2 và 5 đã sửa và phát hành (3.7.12). Điểm 1, 3, 4: user đã chọn làm với kho an toàn mã hóa; THIẾT KẾ bên dưới chờ duyệt trước khi code. Điểm 6 vẫn chờ quyết định.

Audit chỉ-đọc ngày 2026-11-23. Điểm 2 (hộp thoại Loading rồi không có quảng cáo) đã sửa và có test đỏ-xanh. Các điểm dưới đây chưa sửa vì đều là đánh đổi giữa bảo vệ tài khoản và độ bền, hoặc đổi hành vi host nhìn thấy.

## Điểm 5 — Resume App Open dùng placement `splash` (ĐÃ SỬA và ĐÃ PHÁT HÀNH trong 3.7.12, 2026-11-24)

Trước đây `showAppOpenAd` mặc định `AdPlacement.splash` và hai đường resume gọi nó không truyền placement, nên `maxPerPlacementAdsPerDay: {AdPlacement.splash: 1}` (đúng ví dụ README) làm mọi App Open resume bị chặn tới hết ngày UTC.

Đã sửa: resume dùng placement riêng `AdPlacement.custom('app_open_resume')` ở hai lệnh gọi show và ở tra cứu override T181. Test đỏ trước, xanh sau: `test/ad_manager_core_test.dart` → "a per-day cap on the splash placement still lets a resume App Open show".

Thay đổi host có thể thấy: `AdShowEvent.placement` và doanh thu của App Open resume giờ ghi `app_open_resume` thay vì `splash`; `PlacementRegistry` đặt cho `splash` không còn áp lên resume (host muốn thì đăng ký spec cho `app_open_resume`, `format: appOpen`).

## Điểm 1 — Đồng hồ nhảy tiến khóa cap ngày vĩnh viễn

`_todayUtcClamped` lưu mốc ngày cao nhất đã thấy và không bao giờ hạ. Đồng hồ máy đọc 2030 một lần (NTP lỗi, người dùng đổi ngày) rồi trở lại bình thường thì mốc kẹt ở 2030, bộ đếm ngày không bao giờ sang ngày mới, `dailyCapReached()` chặn mọi quảng cáo fullscreen. Chỉ `clearSdkData` hoặc xóa dữ liệu app gỡ được. Đã có test ghi rõ đây là đánh đổi có chủ đích của round-37 (hạ mốc sẽ mở lại lỗ hổng reset cap bằng cách tua lùi đồng hồ). Cần quyết định: giới hạn mốc không được vượt quá N ngày so với đồng hồ thật, hay chấp nhận.

## Điểm 3 — Số lần vi phạm đáng ngờ không suy giảm qua các lần khởi động

`_lastViolationTimestamp` không được lưu, bắt đầu bằng 0 mỗi tiến trình, nên `_decayViolationCount` thoát ngay. Người dùng bình thường vấp cổng CTR/click-spam mỗi tuần một lần ở tiến trình mới thì bộ đếm chỉ tăng, thời gian tạm dừng leo từ 30 phút lên trần 24 giờ. Mâu thuẫn với comment hứa suy giảm theo nửa mỗi 24 giờ.

## Điểm 4 — Force-stop rồi mở lại xóa tạm dừng lưu lượng không hợp lệ đang hoạt động

`_suspiciousPauseUntil`, `_hourlyAdTimestamps`, `_lastFullscreenAdTime` chỉ nằm trong RAM; `resetSession` cũng đặt về 0. Click spam kích hoạt tạm dừng 24 giờ, người dùng force-stop và mở lại thì quảng cáo chạy tiếp. Chỉ số lần leo thang sống sót.

## Điểm 6 — Đồng hồ lùi chặn quảng cáo fullscreen tới lần khởi động kế (độ tin cậy thấp)

`elapsed` âm làm `elapsed < minInterval` đúng, và `removeWhere(now - t > 3600000)` không xóa gì nên cap giờ cũng giữ. Bước lùi nhỏ ít tốn, bước lùi lớn tốn nhiều; trạng thái chỉ trong RAM.

## Thiết kế đề xuất cho điểm 1, 3, 4 (2026-11-24, CHƯA CODE, chờ duyệt)

User chọn làm điểm 3, 4, 1 và lưu bằng kho an toàn mã hóa có sẵn (`flutter_secure_storage`, Keystore/Keychain), theo khuôn `RedeemedKeyLedger`.

### Một bản ghi, một khóa

Lớp mới `SafetyStateStore` (một file nhỏ trong `lib/src/core/`) lưu một JSON dưới khóa `ad_sdk_safety_state_v1`:
`{ "violationCount": int, "lastViolationAtMs": int, "pauseUntilMs": int, "maxObservedDay": "YYYY-MM-DD" }`.

- Ghi tuần tự theo chuỗi tĩnh (`_writeChain`, giống `RedeemedKeyLedger`) để hai lần ghi gần nhau không làm mất nhau.
- **Fail-open:** mọi lỗi đọc hoặc ghi coi như "không có trạng thái" và không bao giờ ném ra ngoài hay chặn quảng cáo.
- Nạp một lần ở `AdSafetyConfig.init` (đã `async`). Ghi mỗi khi `_triggerSuspiciousPause` chạy và khi mốc ngày tăng.

### Điểm 3 (suy giảm vi phạm qua restart)

Nạp `lastViolationAtMs` vào `_lastViolationTimestamp` lúc `init`. Khi đó `_decayViolationCount` (đã có) tự suy giảm nửa mỗi 24 giờ kể từ vi phạm cuối, đúng như comment hứa. `violationCount` vẫn do `AdPreferences.getSuspiciousCount()` cung cấp (không di chuyển, tránh phá dữ liệu cũ); kho mới chỉ thêm các trường còn thiếu.

### Điểm 4 (tạm dừng sống sót qua restart)

Nạp `pauseUntilMs` vào `_suspiciousPauseUntil` lúc `init`. Rủi ro cần chặn: nếu đồng hồ nhảy tiến rất xa thì `pauseUntilMs` có thể đã nằm xa trong tương lai; chặn bằng cách kẹp tối đa `_maxSuspiciousPause` (24 giờ) kể từ bây giờ lúc nạp. `resetSession` hiện đặt `_suspiciousPauseUntil = 0` (comment nói "giống restart"); sau thay đổi này `resetSession` KHÔNG được xóa bản lưu, nếu không thì `destroy()` + `initialize()` vẫn xóa được lệnh tạm dừng (đúng lỗ hổng điểm 4).

### Điểm 1 (đồng hồ nhảy tiến)

Chuyển mốc `maxObservedDay` sang kho an toàn (khó sửa tay hơn `SharedPreferences`) và kẹp: mốc không được vượt quá `ngày thật + 2` ngày. Đồng hồ nhảy tới 2030 một lần thì mốc chỉ lên tối đa ngày thật + 2, rồi tự bắt kịp. Tua lùi đồng hồ vẫn không reset được cap (mốc không bao giờ giảm trừ trường hợp bị kẹp xuống trần). Test round-37 "forward clock jump pins today" hiện đang khẳng định hành vi ghim vĩnh viễn, nên SẼ phải đổi thành "ghim tối đa N ngày": đó là thay đổi quyết định sản phẩm, cần user xác nhận N.

### Rủi ro cần user cân nhắc

1. **Mất khả năng gỡ:** nếu thiết bị lưu trạng thái chặn trong Keychain iOS thì gỡ app không xóa (Keychain sống sót qua gỡ cài đặt). Lệnh tạm dừng tối đa 24 giờ nên hậu quả giới hạn; `clearSdkData(all...)` phải xóa bản ghi này.
2. **Khóa oan:** người dùng bình thường bị tạm dừng 24 giờ thật sự kéo dài qua restart (thay vì mất khi tắt app). Đó chính là ý định, nhưng làm chậm hơn việc app thoát khỏi tạm dừng nhầm do CTR sai.
3. **Dung lượng `lib`:** đang đúng trần 2048KB (đo `du -k` từng file). Một file mới ~4KB làm tổng tăng 4KB, nên phải cắt tương ứng ở chỗ khác.
4. **Test:** mỗi điểm cần test đỏ trước; thêm test cho fail-open (đọc lỗi), cho clamp `pauseUntilMs`, cho `clearSdkData`, và cho việc `resetSession`/`destroy()` không xóa bản ghi.

## Acceptance Criteria (khi quyết định làm)

- [ ] Mỗi điểm được làm có một test đỏ trên bản hiện tại trước khi sửa.
- [ ] Không làm yếu bảo vệ tài khoản: tua lùi đồng hồ vẫn không reset được cap (test round-37 vẫn xanh).
- [ ] `flutter analyze` sạch, `flutter test` xanh, gate size xanh (mind: ~4 byte ở `ad_manager.dart`).
- [ ] CHANGELOG ghi rõ.

## Cập nhật 2026-11-24 (đánh giá độc lập + máy thật)

- Điểm 1 (kẹp mốc ngày N=2) đã HOÀN TÁC (revert 3a3e556): review chỉ ra kẻ tua đồng hồ lùi >2 ngày reset được cap vì trần tính theo đồng hồ hiện tại. User chọn "không bao giờ hạ mốc". Mốc nhảy xa tương lai vẫn ghim như round-37; cần lối thoát khác nếu muốn xử lý.
- Điểm 3, 4: Keystore thật (TECNO KJ7, 3 lần mở/kill): pause còn sau restart, `clearSdkData` xóa bản ghi, khởi động lại vẫn trống.
- Sửa theo review: `clearSdkData` giờ cũng zero đếm vi phạm + risk score trong RAM, và xóa bản ghi ngay sau `prefs.clearSdkData` (trước các bước journal có thể throw).
