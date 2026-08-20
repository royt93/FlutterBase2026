# Audit độc lập `applovin_admob_sdk` — agy CLI (bản hợp nhất, round 1 + round 2)

Hợp nhất `audit_agy_20260815.md` (round 1, version 2.0.4, 700 test) và `audit_agy_20260819_round2.md` (round 2, version 2.1.0, 860 test). Round 2 supersede round 1 khi có xung đột hoặc re-verify cùng finding; phần round 1 chưa được round 2 chạm tới vẫn giữ nguyên, đánh dấu rõ.

**Người audit:** Senior Flutter/Mobile Ads Engineer (agy CLI, cả 2 round).

---

## Trạng thái các bug round 1 sau round 2

| # | Finding round 1 | Trạng thái tại round 2 |
|---|---|---|
| 1.1 | `_admobIsTop` không init đúng khi banner/MREC mount trên route hiện tại → hiện khoảng trắng | **Chưa re-verify riêng ở round 2** — không nằm trong danh sách finding round 2, không có bằng chứng đã fix. Coi là **còn mở, cần audit lại**. |
| 1.2 | `MonetizationArbitrator` lệch tỷ lệ 1000x eCPM → veto gần 100% ad | **Chưa re-verify ở round 2.** Không nằm trong finding round 2 (không rõ đã fix hay round 2 không chạm module này). **Ưu tiên cao cho lần audit sau** — nếu đúng như mô tả, đây là bug mức Blocker (chặn toàn bộ doanh thu), không phải P0 thường. |
| 1.3 | `ConsentManager.showDialog()`/`set()` không gỡ `_footgunBlocked` | Không thấy round 2 nhắc lại trực tiếp — có thể đã fix cùng loạt sửa `autoRequestUmpConsent` default 08-19, nhưng **chưa có xác nhận rõ**. Giữ mở cho tới khi verify. |
| 1.4 | `VipEntriesStore.setRaw` nuốt lỗi Keystore, đánh dấu migrated dù ghi thất bại → mất VIP vĩnh viễn | Không nằm trong round 2. **Chưa verify — giữ mở.** |
| 1.5 | Nhiều `NativeAdWidget`/`BannerAdWidget` cùng lúc trên AdMob crash do singleton `_nativeAd`/`_bannerAd` trong adapter | Không nằm trong round 2. **Chưa verify — giữ mở.** |
| 1.6 | `_lastBackgroundTime` giữ mốc cũ khi Android bắn `paused`/`resumed` dồn nhanh | Không nằm trong round 2. **Chưa verify — giữ mở**, mức độ P2 theo round 1. |

Round 2 tập trung sâu vào 7 khu vực audit chính (dual-provider, offline/online, ad lifecycle/leak, trial/VIP, consent, policy) hơn là re-scan toàn bộ finding cũ — nên các mục trên **không bị bác bỏ**, chỉ đơn giản là round 2 không đi qua lại. Coi 1.1–1.6 là backlog còn treo, ưu tiên xác minh lại 1.2 trước (khả năng ảnh hưởng doanh thu toàn bộ).

---

## Findings round 2 (2026-08-19, version 2.1.0, 860/860 test pass, 0 issues analyze)

### Đã fix trong loạt sửa 08-19 (xác nhận trực tiếp)
1. Show-time freshness validation cho toàn bộ AdMob fullscreen format (`admob_adapter.dart:677-689`).
2. Resumed App Open ad tuân thủ safety cap (`ad_manager.dart:2743-2746`).
3. AppLovin native `MaxAdView` destroy khi widget unmount (`applovin_adapter.dart:157-161,229-233`) — **lưu ý:** round 2 chỉ xác nhận lệnh gọi destroy tồn tại, KHÔNG xác minh sâu native source có thực sự destroy thành công khi view còn attach hay không. Xem `audit_claude.md` mục B1 — vòng audit Claude 08-20 xác nhận native `destroyWidgetAdView` từ chối destroy khi `hasContainerView()==true`, nên leak vẫn tồn tại trong trường hợp dispose khi banner đang hiển thị. **agy round 2 không phát hiện được nuance này** — đáng lưu ý cho phương pháp audit: xác nhận API được gọi không đồng nghĩa hành vi native phía dưới thành công.

### Major/Minor còn mở tại round 2
2. Android Trial/VIP-replay protection hoàn toàn phụ thuộc host tự wire Auto Backup manifest (`_first_install_guard.dart:27-47,126-133`, `_redeemed_key_ledger.dart:16-23,49-51`) — nếu host quên set `allowBackup`/`dataExtractionRules`/`fullBackupContent`, Android user uninstall/reinstall lấy lại trial + tái sử dụng VIP code single-use vô hạn. Đề xuất: thêm check runtime trong `releaseFootgunWarnings` cảnh báo nếu thiếu config này.
3. Consent revoke giữa phiên không tự flush/reload fullscreen slot đã ready trước đó (đề xuất: `AdManager.setConsent`/`_syncConsentToAdapter` nên trigger reload slot đang ready khi consent bị revoke).
4. Rewarded Interstitial trên AppLovin fail không có diagnostic rõ ràng — `shown:false` giống hệt trường hợp "chưa ready" bình thường, không phân biệt được với "provider không hỗ trợ format này" (trùng với `audit_claude.md` finding M4, ở đó có thêm phát hiện orchestrator còn báo sai `shown:true` — 2 vấn đề khác nhau trên cùng 1 tính năng).
5. Clock rollback protection có giới hạn trước lần chạy đầu tiên (`vip_manager.dart:190-198`, `vip_entry.dart:38-41`) — liên quan `audit_claude.md` finding B3 (forward-rồi-lùi), đọc kèm.

### Confirmed-correct (round 2)
- Dual-provider adapter 100% method parity.
- Show-time ad freshness enforcement cho AdMob (4h App Open, 1h interstitial/rewarded).
- Native view disposal — cả AdMob và AppLovin banner/MREC/native đều gọi teardown lúc widget unmount (xem lưu ý ở trên về nuance chưa bắt được).
- Reactive state engine — `ValueNotifier`/`Stream` subscription sạch, không leak qua route transition.
- Offline resilience: mọi async operation có timeout, fail fast khi mất mạng, reload debounce khi reconnect.
- Zero-backend VIP crypto: Ed25519 offline, rotation support, bundle binding, CRL domain-separated.
- Anti-tamper/anti-fraud: daily cap, CTR anomaly detection, click-spam throttle, safety param force-enforce ở release.
- Global privacy compliance: UMP, IAB TCF string, CCPA/RDP per-request tagging, COPPA fail-closed, iOS ATT coordination.
- Reward integrity: reward chỉ cấp qua callback thật, không optimistic granting.

---

## Enhancement / Technical debt / Feature ideas (giữ từ round 1, chưa bị round 2 phủ định)

- Debounce/batch `AdEventLog` — ghi SharedPreferences mỗi event đơn lẻ có thể gây jank ở tần suất cao (`ad_event_log.dart:88-97`).
- Fallback an toàn cho `VipEntriesStore` khi secure storage lỗi trên Android giá rẻ/custom ROM (`_vip_entries_store.dart:42-90`) — liên quan trực tiếp bug 1.4 còn mở.
- `AdManager().vip` trả `null` tới khi init xong, chưa có `ValueListenable` để host lắng nghe thời điểm sẵn sàng thay vì tự poll `initRevision`.
- `NativeAdWidget` cố định `TemplateType.medium`/height 320 — nên cho custom size/template cho in-feed layout.
- Roadmap nâng Flutter 3.38+/Dart 3.10+ để mở khoá `google_mobile_ads` 8/9 (10 điểm pub.dev còn thiếu) — đã biết từ CLAUDE.md, breaking change nếu làm.
- CI iOS simulator vẫn mất 16-18 phút dù đã shard 3 runner — có thể tối ưu thêm boot time/log stream.
- `1 << 62` trong `AdEventLog.inRange` có rủi ro nếu compile sang Web/Wasm (giới hạn 53-bit của JS) — hiện tại không phải target platform nên priority thấp.

## Flagship differentiators (giữ nguyên, không đổi qua 2 round)

- VIP entitlement Ed25519 hoàn toàn offline, bundle-id + expiry binding (AVP2), chống decompile-forge, chống rollback, chống replay reinstall (iOS Keychain).
- Ad Safety Engine nhiều tầng + Policy Risk Score theo thời gian thực — khác biệt rõ so với wrapper ad thông thường.
- Compliance report xuất được 1 dòng code — hữu ích khi tài khoản AdMob/AppLovin bị flag invalid traffic và cần bằng chứng kháng cáo.
- Smart Monetization Arbitrator — **lưu ý:** nếu bug 1.2 (eCPM scale ×1000) chưa fix, tính năng flagship này đang tự chặn gần hết doanh thu thay vì tối ưu nó. Verify bug này trước khi quảng cáo tính năng này với ai.

---

## Khuyến nghị cuối (đứng từ round 2, là kết luận hiện hành)

**YES-WITH-CONDITIONS.**

Điều kiện bắt buộc trước khi deploy production:
1. **Publish version 2.1.0 lên pub.dev** (hoặc pin git ref `main`) — code tại `main` (2.1.0) production-grade, nhưng app không được pull `2.0.4` từ pub.dev vì thiếu các fix 08-16 đến 08-19.
2. Đóng gap Android trial/VIP-replay Auto Backup opt-in (thêm cảnh báo runtime nếu thiếu, hoặc chấp nhận rủi ro có ghi rõ trong README cho từng app).
3. **Xác minh lại bug 1.2 (eCPM scale) và 1.4 (VipEntriesStore nuốt lỗi Keystore) trước khi ship** — 2 bug round 1 chưa được round 2 xác nhận đã fix, và nếu còn đúng, mức độ nghiêm trọng đủ để nâng thành điều kiện bắt buộc chứ không chỉ backlog.
4. Đối với Rewarded Interstitial trên AppLovin: thêm log cảnh báo rõ ràng khi provider không hỗ trợ, tránh host nhầm với lỗi ready bình thường.
