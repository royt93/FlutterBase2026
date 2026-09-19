# Audit độc lập — applovin_admob_sdk v2.9.11 (agy / Gemini, 2026-09-02)

> **Ghi chú của người tổng hợp (Claude, orchestrator round 32):** agent này
> chạy qua `agy --dangerously-skip-permissions` với cwd trỏ vào worktree cô
> lập `audit-gemini`. Trái với 2 agent kia (codex, claude — cả hai đều ghi
> file đúng bên trong worktree được chỉ định), **agy đã không tôn trọng cwd**:
> nó ghi file báo cáo thẳng vào **working tree thật**
> (`packages/ad_sdk/doc/audit/audit_gemini.md`) thay vì vào worktree cô lập —
> may mắn chỉ tạo file mới, không sửa/xoá gì khác (`git status` xác nhận).
> Đã gộp nội dung file đó vào đây (đổi tên theo đúng quy ước cũ của repo:
> `audit_agy.md`, không phải `audit_gemini.md`) rồi xoá file trùng.
> **Rủi ro quy trình cần nhớ cho lần sau: khi chạy `agy` trong worktree cô
> lập, đừng chỉ tin `cd`/cwd — nên tự kiểm tra `git status` ở CẢ working tree
> thật lẫn worktree ngay sau khi agy chạy xong.**
>
> Về nội dung: agent này audit nông hơn 2 agent kia — nó bỏ sót cả 2 BLOCKER
> mà `audit_codex.md` và `audit_claude.md` tìm ra và tự verify được (xem
> `audit_round32_deep_consolidated.md`). Cụ thể, dòng 159 dưới đây khẳng định
> `tcfAllowsPersonalisedAds()` "fail-closed" cho mọi lỗi ngoài `StateError` —
> claim này **sai**: nhánh `try { store = await _open().timeout(5s) } on
> StateError` chỉ bọc riêng lệnh `_open()`, một `TimeoutException` ở đúng chỗ
> này thoát thẳng ra ngoài hàm, không rơi vào nhánh `catch (e)` fail-closed
> phía dưới (nhánh đó chỉ bọc 2 lệnh đọc `getInt`/`getString` phía sau). Giữ
> nguyên văn báo cáo dưới đây làm dữ liệu tham khảo, **không dùng verdict
> "APPROVED FOR PRODUCTION" của báo cáo này làm căn cứ quyết định.**

---

# BÁO CÁO AUDIT TOÀN DIỆN SDK QUẢNG CÁO FLUTTER (APPLOVIN MAX + GOOGLE ADMOB)

**Người thực hiện:** GEMINI (Independent Auditor)
**Phiên bản SDK:** `applovin_admob_sdk` 2.9.11
**Ngày audit:** 2026-09-02
**Mục tiêu:** Rà soát toàn bộ source code (`packages/ad_sdk/lib/`, `packages/ad_sdk/example/`), xác minh luồng gọi thực tế và đánh giá mức độ sẵn sàng cho Production.

---

## TỔNG QUAN KẾT QUẢ AUDIT

Sau khi trace toàn bộ 74 files nguồn Dart và kiểm tra 1553 test cases (1553/1553 tests passed, `flutter analyze` 0 issues), SDK thể hiện mức độ hoàn thiện kỹ thuật rất cao sau 31 vòng audit lặp (round 1-31). Các cơ chế an toàn trọng yếu (teardown mutex, zone error isolation, anti-rollback clock, Ed25519 offline signing, fail-closed TCF parsing, RouteAware/TickerMode visibility hold) đã được gia cố bài bản.

### Bảng phân loại phát hiện (Findings Summary)

| Mức độ | Số lượng | Mô tả ngắn gọn |
|---|---|---|
| **BLOCKER** | 0 | Không còn blocker code-level nào chặn deploy production. |
| **MAJOR** | 3 | Các giới hạn kiến trúc và edge-cases cần lưu ý khi tích hợp vào production app. |
| **MINOR** | 4 | Tối ưu hóa trải nghiệm dev, rotation workflow và document. |
| **NITPICK** | 2 | Code style / comment sync. |

---

## I. AUDIT THEO 8 TIÊU CHÍ BẮT BUỘC

### 1. Dual Provider AdMob / AppLovin
**Đánh giá:** **ĐẠT (PASS)**

- SDK định nghĩa interface chung `AdProviderAdapter` (`lib/src/core/ad_provider_adapter.dart`), được triển khai độc lập bởi `AdMobAdapter` và `AppLovinAdapter`.
- Provider được cấu hình cố định cho từng session process qua `AdConfig.provider`.
- Hỗ trợ A/B testing 50/50 an toàn qua `pickProviderCohort()` dựa trên băm GAID/`installId` ổn định qua các lần mở app.
- Đồng bộ trạng thái & chống race khi re-init: `_destroyInFlight`, `_isInitializing`, `_initGen` (generation token huỷ async op của session cũ).
- Tương thích format: Rewarded Interstitial là no-op an toàn trên AppLovin (không có định dạng này ở MAX SDK); Native Ad dùng template AdMob và custom `MaxNativeAdView` + badge "Ad" cho AppLovin.

### 2. Hoạt động khi có mạng lẫn không có mạng
**Đánh giá:** **ĐẠT (PASS)**

- `AdManager.isConnected` bọc bởi cờ `_connectivityReady` + try-catch, fallback về `_lastConnected` thay vì throw.
- Mọi hàm load/show fullscreen check `!isConnected` đầu hàm, trả fail ngay, không lag channel.
- Khi online trở lại: debounce 800ms, clear cooldown, refill slot, warm-up banner/MREC, retry UMP nếu trước đó fail do offline.
- Mọi platform I/O có timeout cứng (init 20s, ATT 20s, storage 5s, remote config 5s, dispose 4s); toàn bộ Timer được cancel trong `destroy()`.

### 3. Đúng chuẩn cho từng loại Ad
**Đánh giá:** **ĐẠT (PASS)**

- Banner/MREC: `RouteAware` (AppLovin pause refresh, AdMob dispose instance khi route bị che) + `TickerMode` (pause khi tab ẩn qua `Visibility(maintainState: true)`).
- Native Ad: tự giải phóng khi cuộn ra khỏi `ListView`, tự retry lỗi sau 30s.
- App Open: cold-start protection, rapid-resume gate, background tối thiểu 5s.
- Rewarded/Rewarded Interstitial: `earned == true` chỉ khi native SDK gọi `onUserEarnedReward`.
- Chống double-show/stacking: mutex `_fullscreenBusyReason` kiểm tra 9 điều kiện (UMP form, ATT dialog, 4 slot fullscreen, loading dialog, host dialog, teardown đang chạy).

### 4. Trial Mode 1 ngày
**Đánh giá:** **ĐẠT (PASS)**

- iOS: cờ `ad_sdk_first_install_granted_v1` trong Keychain (`first_unlock`), sống sót qua gỡ/cài lại.
- Android: dựa Android Auto Backup — giới hạn kiến trúc đã biết và chấp nhận.
- Chống lùi giờ máy: `VipManager._effectiveNow()` dùng high-water-mark (`vipMaxObservedClockMs`) + monotonic `Stopwatch`, kiểm tra cả 2 chiều `grantedAt`/`expiresAt`.
- `_expiryTimer` tự chuyển `isActive` false giữa session khi hết hạn, reload ads ngay không cần restart app.

### 5. Kích hoạt VIP by Code (Offline)
**Đánh giá:** **ĐẠT (PASS)**

- Ed25519 (`package:cryptography`), verify hoàn toàn offline. Wire format AVP2: `AVP2.<b64(payload)>.<b64(sig)>`, payload gồm seconds/keyId/expiresAtEpoch/bundleId — can thiệp bất kỳ trường nào làm sai chữ ký.
- App chỉ nhúng public key (32 bytes); decompile không tạo được mã mới.
- One-time-use: `RedeemedKeyLedger` — iOS Keychain + `_writeChain` chống race; Android qua `AdPreferences` + Auto Backup. Yêu cầu mạng trước khi redeem (`_isConnectedCheck`) để chặn chia sẻ offline hàng loạt.
- Key rotation qua danh sách public key phân tách dấu phẩy; CRL offline (`CRL1.<payload>.<sig>`, domain-separated, chống replay qua `issuedAt`).

### 6. Consent cho mọi quốc gia (GDPR/EEA, UK, US, COPPA, ATT)
**Đánh giá:** **ĐẠT (PASS)**

- UMP tự chạy trước load ad nếu `autoRequestUmpConsent: true`.
- `IabStorage.tcfAllowsPersonalisedAds()` đọc trực tiếp preference store, phân tích Purpose 1/3/4.
- **Nguyên tắc fail-closed khi lỗi** (⚠️ xem ghi chú orchestrator ở đầu file — claim này không chính xác hoàn toàn): "Nếu đọc store bị lỗi ngoại lệ (ngoài `StateError` trong môi trường test), hàm trả về `false` (fail-closed)".
- CCPA: đọc `IABUSPrivacy_String`, truyền `rdp:1` (AdMob) / `setDoNotSell` (AppLovin), có sẵn widget `CcpaOptOutToggle`.
- COPPA/TFUA: AdMob gán cờ trước `initialize()`; AppLovin tự huỷ/re-init khi cờ trẻ em đổi giữa chừng.
- ATT: `requestAttIfNeeded`, `shouldDeferGaidFetch` hoãn đọc IDFA khi ATT chưa xác định, mutex chặn ad đè lên ATT dialog.

### 7. Tuân thủ Chính sách AdMob & AppLovin
**Đánh giá:** **ĐẠT (PASS)**

- `AdSafetyConfig`: throttle 60s giữa fullscreen ad, cap 6/session-3/giờ-5/ngày, warm-up 10s.
- CTR-fraud >30% → khoá luỹ tiến 30 phút–24 giờ; chống click-spurt >3/phút; chống mỏi mediation (max 4 lần liên tiếp cùng network/15 phút).
- `applyDryRunReleaseGuard` ép `dryRun=false` ở release dù config nhầm.

## II. Findings

- **[MAJOR 1]** Android trial/VIP-ledger không chống được Clear-data/reinstall khi Auto Backup tắt (`_first_install_guard.dart:27-48`, `_redeemed_key_ledger.dart:16-23`) — giới hạn kiến trúc no-backend đã chấp nhận.
- **[MAJOR 2]** `IndexedStack` trần (không bọc `Visibility(maintainState:true)`) khiến banner ở tab ẩn vẫn auto-refresh ngầm (`banner_ad_widget.dart:29-37,92-110`) — vi phạm policy nếu host tích hợp sai.
- **[MAJOR 3]** Key rotation theo danh sách "any-key-matches" (`signed_vip_key.dart:157-190`): nếu private key cũ bị lộ, chỉ thêm key mới lên đầu danh sách mà không xoá key cũ thì mã ký bằng key cũ vẫn hợp lệ — phải chủ động xoá key cũ hoặc dùng CRL.
- **[MINOR 1-4]**: kích thước ledger tăng dần theo thời gian (không đáng kể), route-pause hold đã verify đúng, cache TCF chỉ ảnh hưởng test harness, AVP1 không có bundle-binding (khuyến nghị luôn dùng AVP2).
- **[NITPICK 1-2]**: comment lịch sử cũ trong example, tiền tố log `roy93~` đồng nhất.

## III. Kết luận & điều kiện production (theo agent này — xem cảnh báo ở đầu file)

**KẾT LUẬN (agy/Gemini): APPROVED FOR PRODUCTION.**

Điều kiện tích hợp: (1) thay `kDemoVipPublicKey` bằng keypair riêng qua `tool/vip_keygen.dart`; (2) khai báo `android:allowBackup="true"` + `data_extraction_rules.xml`; (3) bọc tab dùng `IndexedStack` bằng `Visibility(maintainState:true, visible:isCurrentTab, ...)`; (4) khai báo `NSUserTrackingUsageDescription` trong `Info.plist`; (5) thay toàn bộ Ad Unit ID test bằng ID thật trước khi release.
