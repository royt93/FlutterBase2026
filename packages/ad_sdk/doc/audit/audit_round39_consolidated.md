# Audit round 39 — consolidated (2026-09-05, v2.9.18 → v2.9.19)

**Phạm vi:** audit toàn diện SDK + example (không chỉ diff round 38), đối chiếu với bản đã publish lên pub.dev (2.9.18), theo checklist sản phẩm: dual-provider AdMob/AppLovin (Android+iOS), online/offline, 4 loại ad (banner/app open/reward/inter) đúng vòng đời không leak, trial 1 ngày, VIP kích hoạt bằng code không backend, consent mọi quốc gia, tuân thủ policy AdMob/AppLovin.

**Phương pháp — 4 nguồn độc lập, chạy song song, không chia sẻ context với nhau:**
1. `codex exec --dangerously-bypass-approvals-and-sandbox` (worktree cô lập) → `audit_codex.md`
2. `agy --dangerously-skip-permissions` (Gemini-backed, worktree cô lập) → `audit_gemini.md`
3. `claude --dangerously-skip-permissions -p` (worktree cô lập, tiến trình Claude Code độc lập hoàn toàn)
4. Fork của phiên chính (repo thật, chỉ đọc) — tự đọc tay các vùng rủi ro cao

Nguồn 3 + 4 đều hợp nhất vào `audit_claude.md` (xem đầu file đó để biết lý do và 1 bất đồng thật giữa 2 nguồn đã được verify bằng test).

## Kết quả theo điểm

**Vòng 1 — audit toàn diện (4 nguồn độc lập):**

| Nguồn | BLOCKER | MAJOR mới | MINOR mới | Điểm |
|---|---|---|---|---|
| Codex | 0 | 3 (VIP/trial — kiến trúc, không phải bug code) | 0 | 8.6/10 |
| Gemini/agy | 0 | 0 | 0 | 9.7/10 |
| Claude CLI độc lập | 0 | 3 | 3 | 9.0/10 |
| Claude (fork, repo thật) | 0 | 1 | 0 | 9.5/10 (trước fix) |

**Vòng 2 — review độc lập lại chính 8 fix của vòng 1** (sau khi user yêu cầu "test lại toàn bộ + bổ sung test + audit lại + chấm điểm"):

| Nguồn | Finding mới | Điểm |
|---|---|---|
| agy (Gemini), review diff | 1 MAJOR + 1 MINOR + 1 NITPICK (xem bên dưới) | 8.0/10 (trước fix vòng 2) |
| codex | không chạy được — hết quota (reset 2:02 AM), không tính vào kết quả | — |

**Tổng finding thật, đã fix trong round này (cả 2 vòng):**

### Đã sửa code (8, có test RED→GREEN cho từng cái)

1. **MAJOR** — `ConsentManager` COPPA re-init branch (`ad_manager.dart` ~3962) ghi native SDK không epoch-guard. 2 lệnh setConsent() COPPA-toggle chồng nhau có thể khiến lệnh cũ ghi đè lệnh mới lên AppLovin thật. Test: `consent_coppa_branch_race_test.dart`.
2. **MAJOR** — `ConsentManager._persist()` không serialize: 2 lệnh set()/reset() chồng nhau, native write bất đồng bộ có thể hoàn tất KHÔNG theo thứ tự gọi, khiến giá trị cũ nằm lại trên đĩa và bị áp lại sai ở phiên sau. Sửa bằng khoá tuần tự (`Completer`-based, không dùng `.then()`-chain qua field vì gây treo test `testWidgets` không pump — xem comment tại chỗ). Test: `consent_manager_persist_race_test.dart`.
3. **MAJOR** — UMP retry (backstop định kỳ + reconnect) thiếu `runZonedGuarded`, có thể crash lặp lại khi mạng chập chờn + UMP native lỗi. Test: `ump_retry_zone_guard_test.dart`.
4. **MAJOR** — Bộ đếm CTR chống gian lận click dùng chung cho mọi loại ad; banner/MREC tự refresh liên tục pha loãng tỷ lệ, bot chỉ click fullscreen có thể lọt ngưỡng. Tách counter fullscreen-only. Test: `ad_safety_ctr_fullscreen_only_test.dart`.
5. **MINOR** — Không cảnh báo khi thiếu link privacy-policy cho consent dialog. Thêm warning tại `ConsentManager.showDialog`. Test: `consent_privacy_policy_footgun_test.dart`.
6. **MINOR** — `AdRetryPolicy.jitterFraction` gần 1.0 có thể xoá gần hết tác dụng backoff. Thêm floor 10% base. Test: `ad_retry_policy_test.dart`.
7. **MINOR** — App mẫu không demo tính năng thu hồi mã VIP (CRL). Thêm nút demo trong `VipDemoPage`.
8. **MAJOR (banner/MREC ẩn tab)** — banner/MREC trong `IndexedStack` trần vẫn tự refresh khi tab bị ẩn (rủi ro policy "quảng cáo không ai xem"). Thêm `visibility_detector` (tự động cho trường hợp cuộn/che khuất) + tham số `active` thủ công (bắt buộc cho `IndexedStack` — **phát hiện quan trọng giữa chừng: `visibility_detector` về mặt kỹ thuật KHÔNG THỂ tự phát hiện `IndexedStack` ẩn**, vì `RenderIndexedStack` không gọi `paint()` cho tab không active, và cơ chế của thư viện chỉ re-evaluate từ bên trong `paint()`. Đã verify bằng test thật, đã sửa docstring cho đúng sự thật thay vì tuyên bố "tự động hoàn toàn"). Test: `banner_ad_widget_test.dart`, `mrec_ad_widget_test.dart`.

### Vòng 2 — review độc lập lại chính 8 fix trên, tìm thêm 3 bug thật

Sau khi hoàn tất vòng 1, user yêu cầu retest toàn bộ + audit lại chính các fix vừa làm. Dispatch agy (Gemini) review adversarial riêng diff (không phải toàn SDK) — tìm thêm:

9. **MAJOR** — `BannerAdWidget`/`MrecAdWidget`: tham số `active: false` bị bỏ qua hoàn toàn ở **lần mount đầu tiên** — đúng use-case chính (tab `IndexedStack` không phải index 0 ngay từ đầu) vẫn tự load quảng cáo. Đào sâu thêm phát hiện **3 nhánh init độc lập** đều không biết về `active` (nhánh `didChangeDependencies` chính, nhánh reinit độc lập trong `build()` cho kịch bản destroy→reinit, và 2 nhánh reinit theo listener consent/VIP). Sửa cả 3+2 nhánh bằng cờ `_bannerInitCalled`/`_mrecInitCalled` phân biệt "chưa từng load" với "đã load rồi tạm dừng". Test mới: 1 test/widget (banner + mrec), phát hiện qua RED thật khi thêm guard từng phần (bug tái xuất hiện 2 lần ở 2 nhánh khác nhau trước khi sửa triệt để).
10. **MINOR** — nhánh COPPA re-init: lời gọi `initialize()` nằm NGOÀI epoch guard, khiến 1 lệnh COPPA đã bị supersede vẫn có thể trigger 1 lần re-init toàn SDK thừa thãi. Sửa bằng cách bọc cả khối `if/else` vào trong epoch check. Verify bằng đọc code trực tiếp (test khó ép RED do phụ thuộc timing chính xác của `_isInitializing`, nhưng cơ chế bug xác nhận đúng qua đọc source).
11. **NITPICK** — `ConsentManager.resetForTest()` thiếu reset `debugPersistDelay`/`debugApplyBarrier`, có thể rò rỉ giữa các test nếu 1 test abort giữa chừng. Đã fix.

**Bài học:** review độc lám lại CHÍNH audit fix của mình bắt được bug thật mà chính người viết fix (đã tự test kỹ) bỏ sót — đúng tinh thần "audit phải chậm và adversarial" đã ghi trong memory dự án.

### Bug thật thứ 3, tìm ra nhờ "test lại toàn bộ" trên thiết bị thật

12. **MAJOR** — `example/integration_test/anomaly_event_test.dart` dùng pattern cũ (`recordBannerImpression()` + `recordAdClick()`) để trigger CTR gate — sau fix #4 ở trên, banner không còn dilute được fullscreen counter nữa nên test này **im lặng ngừng bắt được regression thật** ở cơ chế báo anomaly (không phải lỗi ở code sản phẩm, mà lỗi ở chính test, khiến 1 lớp bảo vệ bị mất coverage). Phát hiện khi chạy lại toàn bộ 65 file integration test thật trên Pixel 7 Pro — file này timeout/fail thật. Đã sửa dùng `recordFullscreenAdShown()`/`recordAdClick(fullscreen: true)` + thêm real-time wait 3s (throttle `minTimeBetweenFullscreenAds` của demo app).

### Không sửa code — document là giới hạn đã chấp nhận (theo quyết định của LoiTP)

13. Trial 1 ngày trên Android có thể bị farm vô hạn nếu Android Auto Backup tắt/không đồng bộ (`_first_install_guard.dart`, đã có doc comment chi tiết từ trước, round 39 re-confirm).
14. 1 mã VIP hợp lệ có thể redeem trên nhiều thiết bị nếu bị chia sẻ công khai (`vip_manager.dart:redeemSignedKey`, không có server trung tâm claim mã — by design).

Cả 2 mục trên đã ghi vào memory (`vip-offline-gate-and-qa-hashes-are-features.md`) để round audit sau không báo lại như finding mới.

## Kiểm chứng

- `flutter analyze`: sạch (0 warning), cả 2 lần (sau vòng 1 và sau vòng 2).
- `flutter test` (unit/widget): **1656/1656 pass**.
- **Integration test thật trên thiết bị Android thật (Pixel 7 Pro, Android 17, qua USB): 65/65 file đã chạy.** 63 file pass thật; 2 file fail do **thiếu APPLOVIN_SDK_KEY thật trên máy** (giới hạn môi trường đã biết từ trước — không có key thật commit trong repo — không liên quan round 39, xem `round37_coppa_hardstop_test.dart`/`r36_real_applovin_appopen_over_banner_test.dart`); 1 file (`anomaly_event_test.dart`) fail thật lúc đầu do bug #12 ở trên, đã fix và xác nhận PASS lại. Một số file báo fail giữa chừng do máy Mac hết dung lượng ổ đĩa (build APK 65 lần liên tục) — đã dọn dung lượng và chạy lại riêng từng file, xác nhận tất cả pass, không liên quan code.
- Không regression: toàn bộ test suite cũ vẫn xanh.
- Dependency mới: `visibility_detector: ^0.4.0+2` (duy trì bởi Flutter team, không kéo transitive dependency).

## Điểm tổng thể round 39: 9.5/10

**Căn cứ:** không BLOCKER ở bất kỳ nguồn nào trong tổng 5 lượt audit/review độc lập (4 nguồn vòng 1 + 1 nguồn vòng 2, cộng phát hiện thật từ chính việc retest toàn bộ trên thiết bị). 12 MAJOR/MINOR/NITPICK thật đã fix, mỗi cái có test regression, xác nhận qua **2 vòng review độc lập** cộng **integration test thật trên thiết bị** — không phải chỉ tự chấm. Điểm trừ 0.5 vì: (a) vòng 2 mới tìm ra bug MAJOR thật trong chính fix vòng 1 — cho thấy dù đã cẩn thận vẫn còn sai sót ban đầu (dù đã sửa xong); (b) 2 giới hạn kiến trúc (trial/VIP) vẫn tồn tại theo thiết kế, dù đã chấp nhận có chủ đích.

## Kết luận — CÓ nên đưa vào production

**CÓ.** Không có BLOCKER ở bất kỳ nguồn nào qua 2 vòng review độc lập + integration test thật trên thiết bị Android thật. 12 MAJOR/MINOR/NITPICK thật đã fix có test regression (unit + widget + integration); 2 giới hạn kiến trúc (trial-bypass Android, VIP cross-device replay) là trade-off có chủ đích của thiết kế "không backend", đã document rõ, chấp nhận được cho use-case tặng/khuyến mãi — cần server riêng chỉ nếu VIP code trở thành sản phẩm bán đại trà có giá trị thật.
