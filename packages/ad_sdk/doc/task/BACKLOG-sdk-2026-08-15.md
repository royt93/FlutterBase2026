# Backlog SDK — Audit round mới sau khi prune host app (2026-08-15)

## Bối cảnh

Repo vừa prune host app ra khỏi repo (commit `a684b0a`), chỉ còn `packages/ad_sdk/`. Track SDK `T01-T56` (xem `doc/task/README.md`) đã done hết. Đây là audit round mới, full scope, chỉ cho `packages/ad_sdk/`.

## Phương pháp

4 agent độc lập audit song song toàn bộ `packages/ad_sdk/` (`lib/`, `test/`, `example/`, docs, CI), mỗi agent tự đọc source không tham khảo nhau:

1. **codex CLI** (`codex exec`) → `doc/audit/audit_codex_20260815.md`
2. **agy CLI** (`--dangerously-skip-permissions`) → `doc/audit/audit_agy_20260815.md`
3. **Claude subagent** (general-purpose, tự fork thêm 3 sub-audit con cho lib/test/example+CI+docs) → `doc/audit/audit_claude_native_20260815.md`
4. **gemini CLI** — **thất bại**, tài khoản báo `IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals` (cần migrate Antigravity), không phải lỗi từ phía audit. Bỏ qua, chỉ có 3/4 góc nhìn.

Sau đó 1 fork verify độc lập đọc lại source thật để confirm/refute các claim quan trọng hoặc mâu thuẫn giữa 3 báo cáo trước khi chốt thành ticket — tránh lặp lại lỗi audit cũ (ví dụ tin nhầm 1 nhận định đã sai phạm vi). Kết quả verify:

| Claim | Verdict | Ghi chú |
|---|---|---|
| eCPM lệch x1000 (`MonetizationArbitrator`) | **CONFIRMED** | guardrail `maxVetoRate` chặn không cho veto 100%, nhưng đơn vị vẫn sai-theo-thiết-kế |
| `_admobIsTop` không set true ở route đầu | **CONFIRMED** | banner + mrec đều dính, gap test có thật |
| `VipEntriesStore.setRaw` nuốt lỗi ghi | **CONFIRMED** | mất VIP vĩnh viễn khi Keystore lỗi |
| `canShowInterstitial`/`canShowRewardedAd` thiếu check | **PLAUSIBLE, hẹp hơn báo cáo gốc** | chỉ gap khi consent/network đổi SAU KHI ad đã cache |
| README sai default `autoRequestUmpConsent` | **CONFIRMED** | doc nói `false`, code default `true` |
| UMP channel-error fail-open | **REFUTED — không phải bug** | có comment xác nhận đây là tradeoff cố ý, tránh lặp lại bug C1 |
| Footgun `_footgunBlocked` scope (agy: rộng vs claude: hẹp) | **claude đúng phạm vi thật** | chỉ trip khi `autoRequestUmpConsent:false` + dùng dialog built-in, không ảnh hưởng config mặc định |
| `suspiciousViolationCount` không decay (claude_native) | **Đã có decay (T25, 2026-07-09) — claim gốc sai; nhưng có 1 gap thật khác** | counter tự nó decay đúng; gap thật là **snapshot/compliance report đọc raw counter lag so với decay real-time dùng cho `policyRiskScore`** → viết lại thành T68 đúng phạm vi |

Các claim còn lại (đến từ 1 nguồn duy nhất, không kịp verify riêng trong vòng đầu) được đưa vào backlog với ghi chú "chưa verify độc lập" — **vòng verify thứ 2 (2026-08-15, cùng ngày)** đã xử lý hết 5 ticket này qua codex/agy/claude CLI độc lập:

| Ticket | Verdict | Ghi chú |
|---|---|---|
| T62 — AppLovin Native gate re-check | **PLAUSIBLE, thu hẹp** | thêm phát hiện phụ: cold path AppLovin có vòng phụ thuộc khiến `MaxNativeAdView` chưa mount |
| T63 — `destroy()` thiếu reset guard flag | **PLAUSIBLE, thu hẹp** | cả 4 field đúng là không reset, nhưng mức ảnh hưởng khác nhau — `_canRequestAds`/`_umpAttemptFailed` đáng kể nhất, `_lastUmpResult`/`_attRequested` rủi ro thấp hơn claim gốc |
| T65 — Nhiều Native/BannerAdWidget xung đột AdMob | **CONFIRMED** | `google_mobile_ads` ném `FlutterError` khi 2 `AdWidget` share 1 `AdWithView` instance — adapter lưu singleton, xác nhận đúng |
| T66 — `_lastBackgroundTime` stale khi resume nhanh | **CONFIRMED** | xác nhận bằng chuỗi lifecycle `resumed→inactive→resumed` không qua `paused`, có thể khiến App Open hiện ngoài ý muốn |
| T67 — Reconnect không refill preloadMrec/Native | **CONFIRMED, thu hẹp** | gap thật không phải "chưa mount widget" như đoán gốc, mà là `preloadMrec()`/AdMob mrec-native recovery chỉ chạy lúc init/lifecycle-resume, không chạy lúc reconnect thuần |

Không claim nào bị REFUTE ở vòng verify thứ 2 — cả 5 ticket đều giữ trong `todo/`, đã bỏ tag "chưa verify độc lập", nội dung file đã cập nhật bằng chứng dòng code thật.

## Vòng thực thi (TDD) — T57 hoá ra là REFUTED

Khi bắt tay implement T57 theo TDD (viết test trước khi sửa code), test **pass ngay lập tức** — dấu hiệu kinh điển là đang test hành vi đã đúng, không phải bug. Đọc lại source Flutter SDK thật (`routes.dart:2431-2436`) xác nhận `RouteObserver.subscribe()` **luôn luôn** gọi `didPush()` ngay khi subscribe, không điều kiện theo `route.isCurrent`. Claim gốc ("RouteObserver không tự fire didPush() cho route đã active — hành vi chuẩn Flutter") sai ngay ở giả định về Flutter, không phải sai phạm vi — và đã được **2 audit độc lập + 1 pass verify riêng đều xác nhận CONFIRMED** mà không ai đọc lại Flutter SDK source thật.

→ **T57 chuyển REFUTED**, `doc/task/done/T57-admob-top-flag-first-route.md`. **T81 (test bổ sung) vẫn đóng bình thường** — 2 test mới (banner + mrec, mount làm `home:`) được giữ lại làm regression test khoá đúng hành vi, dù không phải fix bug.

**Bài học cho các vòng verify sau:** review-code/đọc-mô-tả suông (kể cả đọc lại source SDK của mình 2-3 lần độc lập) không đủ để bắt giả định sai về hành vi của 1 dependency bên ngoài (ở đây là Flutter framework) — chỉ có viết test thật và quan sát nó pass/fail mới lộ ra. Áp dụng TDD nghiêm túc cho từng ticket còn lại (T58, T59...) trước khi tin tưởng bất kỳ claim "CONFIRMED" nào là chắc chắn đúng.

## Tổng số ticket: T57–T99 (43 ticket)

| Mục | Range | Số lượng |
|---|---|---|
| 1. Bug cần fix | T57–T68 | 12 |
| 2. Enhancement | T69–T79 | 11 |
| 3. Task mới / nợ kỹ thuật | T80–T87 | 8 |
| 4. Ý tưởng tính năng mới | T88–T94 | 7 |
| 5. Flagship / độc quyền | T95–T99 | 5 |

Chi tiết từng ticket: file riêng trong `doc/task/todo/T57-*.md` … `T99-*.md`. Ưu tiên xử lý theo thứ tự: **T57, T58, T59** (3 bug P0/P1 confirmed, ảnh hưởng doanh thu + mất dữ liệu VIP thật) trước, còn lại theo P1 → P2.

## Nguồn

`doc/audit/audit_codex_20260815.md`, `doc/audit/audit_agy_20260815.md`, `doc/audit/audit_claude_native_20260815.md`. Baseline đã đọc trước khi audit: `doc/task/README.md` (T01-T56), `doc/audit/audit_full_20260711.md`, `doc/audit/audit_claude_20260802.md`, `doc/audit/release_1_2_4_and_ci_findings_20260801.md`.
