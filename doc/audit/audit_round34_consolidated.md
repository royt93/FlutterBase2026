# Audit round 34 consolidated — applovin_admob_sdk 2.9.15

Ngày: 2026-09-03. Bối cảnh: audit toàn diện theo yêu cầu chủ dự án, đối chiếu với
version publish trên pub.dev (2.9.15, khớp đúng local, published "in the last
hour" tại thời điểm audit). Sau 33 vòng audit trước, vòng này chạy độc lập
nhiều agent + tự orchestrator verify lại từng finding gây tranh cãi bằng cách
đọc source thật, không chỉ tin báo cáo của agent nào.

## Agent đã dùng và agent không dùng được

| Công cụ | Kết quả |
|---|---|
| Codex (`gpt-5.6-sol`, `codex exec --dangerously-bypass-approvals-and-sandbox`) | Hoàn thành, có lần vào source thật `applovin_max-4.6.4` trong pub-cache để verify. Hết usage limit ngay sau khi ghi xong report (không ảnh hưởng report). |
| Claude (headless, `claude -p --dangerously-skip-permissions`) | Hoàn thành, chạy `flutter analyze`/`flutter test` thật (1571/1571 pass), tự tay giải mã bit GPP để verify round-33 fix. |
| Gemini CLI (`gemini -y -p`) | **Không dùng được** — tài khoản free tier bị chặn (`IneligibleTierError`, Google yêu cầu chuyển sang Antigravity). |
| agy (`agy --dangerously-skip-permissions`) | **Không dùng được** — chưa đăng nhập trong môi trường này (`authentication required`). |

Chỉ 2/4 công cụ độc lập chạy được vòng này. Điều này tự nó là một giới hạn của
báo cáo — ít hơn round 33 (3 agent).

## Hai agent ra hai verdict khác nhau — như mọi round trước

| Agent | BLOCKER | MAJOR | Verdict |
|---|---|---|---|
| Codex | 1 | 5 | **Không approve nguyên trạng** |
| Claude (headless) | 0 | 0 (+ 1 finding mới MINOR-MAJOR) | **Dùng được cho production, kèm điều kiện** |

Đọc kỹ cả 6 finding của Codex thì thấy **5/6 không phải phát hiện mới** — chúng
là các giới hạn đã được audit trước đó (round 29/32/33) tìm ra, cân nhắc, và
**chủ động quyết định không sửa** vì lý do kiến trúc (không backend) hoặc giới
hạn dependency, rồi ghi thẳng vào README "Known limitations" / CLAUDE.md thay
vì giấu đi. Codex không đọc phần "Known limitations" của README trước khi kết
luận "BLOCKER", nên đánh giá đúng cơ chế nhưng sai về tính mới/mức độ khẩn cấp.

## Tự verify từng finding (đọc source thật, không tin báo cáo nào)

### Đã xác nhận: không mới, đã công bố, đã quyết định từ trước — không cần hành động thêm

- **R34-01 (Codex, BLOCKER) — trial/VIP Android bypass qua uninstall/reinstall**:
  cơ chế đúng 100% (`FirstInstallGuard` không có backstop trên Android, dựa vào
  Auto Backup best-effort). Nhưng README.md dòng 61-71 ("VIP anti-bypass is
  durable on iOS, weak on Android") đã công khai **chính xác** kịch bản này từ
  trước, kèm khuyến nghị dùng AVP2 với `--valid-days` ngắn. Không phải lỗ hổng
  ẩn — là tradeoff đã cân nhắc cho một SDK cố tình không có backend.
- **R34-02 (Codex, MAJOR) — key hợp lệ không one-time toàn cầu, AVP1 không có
  expiry/app-binding**: đúng cơ chế, đã công bố ở README dòng 72-81 ("A leaked
  key is a leaked key — mitigated, not eliminated"). AVP1 giữ lại có chủ đích
  (backward-compat cho key đã phát hành trước AVP2), có đường nâng cấp
  (`refreshRevocationList`).
- **R34-04 (Codex, MAJOR) — AppLovin consent setter fire-and-forget, không
  await được**: chính là R33-01 đã tìm thấy round 33, quyết định **không sửa
  code** (giới hạn API `void` của dependency `applovin_max`, không phải bug
  phía SDK này), ghi vào README dòng 111-121. Codex tự lần vào
  `applovin_max-4.6.4/lib/applovin_max.dart:191-210` xác nhận đúng — verify
  chất lượng tốt, nhưng đây là round thứ 2 liên tiếp tìm lại đúng finding này.
- **R34-05 (Codex, MAJOR) — `bypassSafety` không có enforcement thật**: đọc
  `ad_manager.dart:5910-5926` — chính comment tại chỗ ghi rõ đây là "round-32
  audit — flagged again as a footgun risk, kept as a public param by design"
  kèm `bypassAuditTrail` (audit-trail sau sự kiện, không phải enforcement,
  đúng như Codex mô tả) được thêm **vì đã biết** giới hạn này. Không mới.

Bài học lặp lại từ round 32/33 ([[audit-must-be-slow-and-adversarial]],
[[vip-offline-gate-and-qa-hashes-are-features]]): agent audit mới luôn có xu
hướng tái phát hiện các tradeoff đã cân nhắc kỹ và công bố công khai, gắn nhãn
BLOCKER/MAJOR như thể chưa ai biết. Giá trị thật của các agent này nằm ở việc
**verify lại cơ chế còn đúng không sau các lần sửa gần đây** (nó đúng), không
phải ở tính mới của finding.

### Xác nhận MỚI và THẬT — cần xử lý

**F1 (MAJOR, docs) — README nói sai về mức độ hỗ trợ GPP sau round 33.**
`README.md:1928-1934` ("CCPA / US state privacy") vẫn viết *"The GPP string is
not decoded... exposed raw and nothing more"* — đúng ở bản 2.9.13 trở về
trước, nhưng round 33 (2.9.15) đã thêm `IabStorage._gppUsNationalOptedOut()`
(`lib/src/core/iab_storage.dart:229-247`) giải mã một phần section US National
của GPP. Tài liệu hiện **không khớp code**, gây hiểu lầm cho người tích hợp
hoặc reviewer pháp lý về phạm vi thật.

Đối chiếu source (đã tự verify bằng tay ở round này, khớp round-33 report):
code chỉ đọc 2 field `SaleOptOut`/`SharingOptOut` trong Core Segment US
National, **không đọc** `TargetedAdvertisingOptOut` (field ngay kế bên, có
tên trong chính doc-comment của hàm) và **không đọc bất kỳ section theo bang
nào** (California, Colorado, Virginia, Connecticut...) dù các bang đó có
quyền "opt out of targeted advertising" tách biệt với "opt out of sale". Đây
là giới hạn *có chủ đích* (comment: "mis-parsing a privacy signal is worse
than not reading one") — hợp lý về mặt kỹ thuật, nhưng README cần nói đúng
phạm vi hiện tại thay vì câu cũ đã lỗi thời.

**F2 (MAJOR, config mặc định) — App mẫu ghi đè default an toàn, log raw GAID
ở release.** SDK core đã tự sửa "N1: unsafe-by-default logging footgun" —
default hiện tại đúng là
`logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning`
(`ad_config.dart:392`). Nhưng `example/lib/main.dart:264` **ép cứng**
`logLevel: AdLogLevel.verbose` không điều kiện `kDebugMode`. Vì
`SafeLogger.d(_tag, () => 'GAID=$_currentDeviceGAID')`
(`ad_manager.dart:2230`) log raw advertising ID ở mức verbose, build **release**
của app mẫu vẫn in raw GAID vào `LogBuffer`. App mẫu là template tích hợp
chính thức (README dẫn người dùng đọc nó) — rủi ro copy-paste nguyên cấu hình
này vào app thật là có thật.

**F3 (MINOR-MAJOR, git hygiene, ngoài phạm vi code SDK) — khoá ký Play App
Signing từng bị commit vào git history.** Xác nhận bằng
`git cat-file -p 60a1f3d:android/app/private_key.pepk` (commit `60a1f3d`,
2024-12-20, message "up") — blob PEPK thật, hiện không còn trong HEAD nhưng
vẫn lấy được nguyên vẹn qua lịch sử. File là bản mã hoá bằng public key của
Google (định dạng PEPK upload key cho Play App Signing) nên bản thân nó
**không** cho phép ký app ngay nếu không có private key phía Google — rủi ro
phụ thuộc việc repo có từng/sắp public hay thêm collaborator không tin cậy
hay không. Đây là tàn dư từ thời host app còn sống chung repo (theo CLAUDE.md,
nay đã tách riêng) — không phải lỗi của package `ad_sdk`, nhưng cùng git
history nên vẫn là rủi ro thật của **repo này**.

## Các trục đã audit và xác nhận ổn (không lặp lại chi tiết — xem 2 báo cáo gốc)

Dual-provider Android/iOS không lệch logic tầng Dart; connectivity watch có
generation-token chống leak, mọi Timer/Subscription có điểm huỷ tương ứng
(verify chéo bằng grep từng field, không chỉ đọc tên hàm); VIP Ed25519 domain
-separation đúng giữa CRL và key thường; COPPA hard-stop AppLovin thật (test
riêng); ATT có timeout + ref-count tránh chồng UMP; ví dụ tích hợp tuân đúng
hợp đồng README (setNavigatorKey trước runApp, 2 observer, init trong splash,
dispose listener). Chi tiết đầy đủ: `audit_codex_round34.md`,
`audit_claude_round34.md`.

**Chưa kiểm chứng vòng này** (khai báo minh bạch, cả 2 agent lẫn orchestrator
đều không đủ điều kiện): chạy trên thiết bị/simulator thật, tra cứu CVE cho
native SDK (`AppLovinSDK 13.6.3`, `google_mobile_ads` 7.0.0 native), đọc sâu
toàn bộ `compliance/` và `monetization/` (hash-chain audit log, waterfall
tuner — nằm ngoài 8 trục bắt buộc).

## Khuyến nghị production

**Dùng được cho production**, với các điều kiện — không đổi nhiều so với các
round trước, cộng 3 việc nhỏ mới của round này:

Điều kiện đã biết từ trước (chấp nhận, không phải chặn):
1. Chấp nhận VIP/trial trên Android chỉ "weak, mitigated" — dùng AVP2 với
   `--valid-days` ngắn thay vì phát key vô thời hạn quy mô lớn.
2. Chấp nhận AppLovin consent-write không verify được ở tầng platform-channel
   (giới hạn dependency, không sửa được từ code SDK).
3. Không dùng `bypassSafety` ngoài đúng 1 điểm gọi ở splash — đây là honor
   system, không có enforcement kỹ thuật.

Việc nên làm trước khi release tiếp (mới phát hiện round 34, chi phí thấp):
4. Cập nhật README mục "CCPA / US state privacy" cho khớp code sau round 33 —
   nói rõ hiện tại chỉ đọc Sale/SharingOptOut của US National GPP, chưa đọc
   `TargetedAdvertisingOptOut` và chưa đọc section theo bang.
5. Sửa `example/lib/main.dart:264` dùng `kDebugMode ? verbose : warning` thay
   vì ép cứng `verbose`, khớp default an toàn mà chính SDK core đã tự áp dụng.
6. Xác minh khoá `private_key.pepk` (đã xoá khỏi HEAD) có từng active trên
   Play Console không; nếu có, cân nhắc rotate qua Play Console và purge khỏi
   git history trước khi mở quyền truy cập repo.

Không có finding nào ở round 34 đủ để hạ mức "dùng được" xuống "không nên
dùng" — codebase vẫn giữ kỷ luật kỹ thuật cao (dispose/lifecycle nhất quán,
mọi claim "đã fix" ở round 33 verify lại bằng tay đều đúng thật), và các
BLOCKER/MAJOR do Codex nêu đều là rủi ro đã biết, đã cân nhắc, đã công bố —
không phải lỗ hổng mới phát sinh.
