Audit round 30 — subsystem còn sót của round 29

**Ngày:** 2026-09-02
**HEAD tại thời điểm bắt đầu:** `c83c00b` (2.9.9, sau round 29 + follow-up AppLovin)
**Bối cảnh:** round 29 dùng 6 agent đọc hết `core/`, `state/`, `vip/`, `monetization/`, `widget/`, `adaptive/`, `consent/`, `compliance/`, `adapters/admob_adapter.dart`+`applovin_adapter.dart`+`gma_bridge.dart`. Round 30 lấp 2 khoảng trống còn lại: `lib/src/utils/` (826 dòng — nền persistence + async_epoch) và `lib/src/config/` + `applovin_bridge.dart` (880 dòng — cấu hình trung tâm, remote safety provider, lớp gọi native AppLovin thật). 2 agent song song, cùng phương pháp: đọc hết, không tin baseline, hunt bug thật.

## Kết quả: 4 MAJOR + 1 MINOR (doc), tất cả fixed, RED→GREEN verify thật

### MAJOR 1 — AppLovin test-device registration là no-op vĩnh viễn cả 2 platform
`applovin_adapter.dart` — `setTestDeviceAdvertisingIds` gọi SAU `_bridge.initialize()`. Agent tự verify bằng cách đọc source thật `applovin_max` 4.6.4 native plugin (Android `.java` + iOS `.m` trong pub-cache): field đó chỉ được đọc **1 lần duy nhất** bên trong chính `initialize()` rồi null hóa ngay. Gọi setter sau khi init xong ghi vào chỗ không ai đọc lại nữa — device dev/QA KHÔNG BAO GIỜ thực sự được đăng ký test device trên AppLovin, dù comment 2 dòng trên tự nhận "required... failing to do so risks account suspension". Ngược hẳn với 15 dòng consent flags ngay phía trên (được gọi ĐÚNG thứ tự, trước init, lý do MJ1). **Fix:** đổi chỗ block gọi lên trước `_bridge.initialize()`, khớp đúng pattern consent.

### MAJOR 2 — `refreshRemoteSafetyParams()` xóa mất giai đoạn ramp
`ad_manager.dart` — merge remote override lên `cfg.safety` (config gốc) thay vì `effectiveSafety` (đã áp `safetyRampSchedule`). Mọi field ramp đã chỉnh (mà remote payload không đề cập) bị reset về config day-0 mỗi lần refresh — ngược lời doc comment tự hứa "remote luôn thắng field cả 2 đụng, KHÔNG PHẢI ramp". **Fix:** factor ra `_rampAdjustedSafety(config, prefs)` dùng chung cho cả `initialize()` và `refreshRemoteSafetyParams()`, tính lại mỗi lần gọi (ramp theo thời gian, không cache).

### MAJOR 3 — Remote safety override không có ceiling
`remote_ad_safety_provider.dart` — chỉ `dryRun` được chặn khỏi remote payload nguy hiểm (theo đúng tinh thần R12-A `applyDryRunReleaseGuard`). 6 field số khác (throttle/cap) không có chặn trên: remote payload có thể set `minTimeBetweenFullscreenAds: 0` (giết throttle chống gian lận) hoặc `maxFullscreenAdsPerDay` lên số khổng lồ (coi như unlimited). **Fix:** thêm `min`/`max` cho từng field — 2 field throttle (`minTimeBetweenFullscreenAds`, `minTimeAppOpenResume`) bắt buộc `>= 1`, các field cap có ceiling hợp lý (500/day, 100/hour&session, 60/phút).

### MINOR đi kèm M3 — `posInt()` từ chối double hợp lệ
Cùng file — `v is int` chặt hơn `unitDouble()`'s `is num`. Backend remote-config emit `8.0` cho field nguyên bị âm thầm rớt. **Fix:** chấp nhận double nguyên giá trị (`8.0` → `8`), vẫn từ chối phân số (`8.5`).

### MAJOR 4 — `AdPreferences.getInstance()` không phải singleton an toàn thật
`ad_preferences.dart` — check `_instance == null` TRƯỚC `await`, không check lại SAU. 2 caller đồng thời trước lần set đầu đều qua được null-check, tạo 2 object riêng biệt. Agent tự verify bằng thực nghiệm (viết + chạy + xóa file test tạm): dựng race thật, chứng minh 1 sample bị rớt khỏi lịch sử fill-rate baseline vì mỗi object có `_fillRateBaselineChain` (hàng đợi tuần tự hóa write) riêng. Đường gọi thật tồn tại: `experimentBucket()`'s pre-init call (`unawaited`) + `initialize()`'s riêng gọi `getInstance()` — 2 caller khác nhau, race có thật dù bị kiềm chế bởi kiến trúc hiện tại (không phải đảm bảo). **Fix:** `Completer`-based guard giống hệt cách `SharedPreferences.getInstance()` (bên dưới) tự làm.

## Đối chiếu tự verify trước khi tin agent

Agent config/bridge còn báo 1 "nit" — 4 accessor split-key VIP-revocation (`getVipRevocationCacheRaw`/`getVipRevocationPublicKey`/`setVipRevocationCacheRaw`/`setVipRevocationPublicKey`) "dead code, xóa được". Tự grep lại rộng hơn (agent chỉ grep `lib/`, bỏ sót `test/`) phát hiện `setVipRevocationCacheRaw` **đang được dùng thật** trong `test/vip_revocation_test.dart` để dựng kịch bản crash-recovery (cache CRL không kèm pubkey, mô phỏng crash giữa chừng). Không xóa — bài học: luôn tự verify claim "unused"/"dead code" bằng grep toàn repo (kể cả `test/`, `example/`) trước khi hành động, đừng tin phạm vi grep của agent.

## Verify cuối

`flutter analyze` 0 issues, `flutter test` 1515/1515 (từ baseline 1505 sau round 29 + follow-up → +10 test mới round 30). Mỗi fix RED→GREEN mutation-verified thật (revert bằng patch đã lưu, xác nhận test đỏ đúng lý do, áp lại, xanh).

## Verdict

Không BLOCKER mới. 4 MAJOR đều là "âm thầm sai/mất tác dụng" (test-device không đăng ký được, ramp bị xóa, safety layer có thể bị remote defeat, race hiếm ở persistence layer) — không phải data-loss hay lỗ hổng khai thác trực tiếp, nhưng đủ nghiêm trọng để chặn tự tin production trước khi vá. Sau fix: **YES WITH CONDITIONS** không đổi so với round 29 — điều kiện còn lại vẫn chỉ là BLOCKER key-rotation cũ (ngoài phạm vi code, risk-accepted).

**Bài học phương pháp round 30:** đọc hết 2 khu vực nhỏ hơn nhiều (utils 826 dòng + config/bridge 880 dòng, so với round 29's 3000-11000 dòng/agent) vẫn tìm ra 4 MAJOR thật — xác nhận lại: lỗ hổng không tỷ lệ với kích thước file, mà với việc CÓ ai đọc hết nó chưa. Repo này giờ đã có "coverage" đọc-hết-từ-đầu cho toàn bộ `lib/src/`.
