# Audit SDK — applovin_admob_sdk, góc nhìn "partner mobile lead" (2026-07-10)

Người audit: Claude (Sonnet 5). Vai trò giả định: mobile lead của một đối tác đang cân nhắc tích hợp SDK này vào app của họ (không phải người đã xây SDK).

Phạm vi: không lặp lại nội dung đã audit kỹ ở 3 round trước (`audit_claude.md`, `audit_codex.md`, `audit_gemini.md`, T01–T28 done 100%). Round này verify lại state hiện tại (test/analyze thật) + đào sâu các rủi ro **vận hành/adoption** mà một đối tác mới sẽ va phải trước khi chạm tới compliance code — góc mà 3 round trước chưa audit vì họ đứng từ vị trí "team đang sở hữu SDK", không phải "team sắp import SDK".

## 0. Verify lại state hiện tại (không chỉ tin doc cũ)

Chạy thật, không suy diễn từ changelog:

- `cd packages/ad_sdk && flutter analyze` → **No issues found**.
- `flutter analyze` (host root) → **No issues found**.
- `flutter test` (ad_sdk) → **428/428 pass**.
- `flutter test` (host root) → **76/76 pass**.

Khớp với claim trong `doc/feature.md`/changelog. Code state hiện tại (bao gồm commit mới nhất `0baea8c` — durable iOS Keychain ledger cho signed VIP key chống replay qua uninstall/reinstall) đã được review nhanh: thiết kế fail-open đúng đắn (lỗi Keychain → coi như chưa redeem, không khoá nhầm người dùng hợp lệ), có test riêng (`redeemed_key_ledger_test.dart`), và đúng pattern đã dùng cho `FirstInstallGuard`. Không có finding mới ở phần này.

## 1. [CRITICAL] Package pub.dev **stale** so với code đang chạy/test thật

`pubspec.yaml` (host, dòng 48-53):

```
# Hosted — 1.0.23 on pub.dev. TEMPORARILY overridden local path below
applovin_admob_sdk: ^1.0.23   # (commented out)
applovin_admob_sdk:
  path: packages/ad_sdk        # ACTIVE
```

`packages/ad_sdk/pubspec.yaml` cũng ghi `version: 1.0.23` — **cùng số** với bản đã publish, nhưng nội dung local đã đi xa hơn nhiều: T21/T22/T28, VIP grace nudge, và toàn bộ ledger chống replay signed-key (`0baea8c`, hôm nay) đều **chưa từng lên pub.dev**.

Vấn đề với một đối tác mới: nếu họ (hoặc một dev khác trong chính team này 3 tháng nữa) làm theo README và chạy `flutter pub add applovin_admob_sdk`, họ nhận **bản 1.0.23 cũ** — thiếu toàn bộ fix bảo mật/compliance mới nhất, và version number không hề tăng nên `pub outdated` sẽ không báo gì bất thường (cùng version, khác nội dung — không phải semver hoạt động đúng cách).

**Rủi ro cụ thể:** mọi audit trước đây (bao gồm cả round này) đều verify trên **local path**, không phải trên artifact thật sự được phân phối qua pub.dev. Nếu đối tác build production từ bản hosted, họ ship code **chưa qua các round audit gần nhất**.

**Khuyến nghị:** bump version thật (vd `1.0.24`) mỗi lần merge local path vượt qua bản hosted, và publish trước khi bản hosted "lệch" quá xa — hoặc ghi rõ trong README ngay đầu file: "hosted pub.dev có thể lag sau `main`, dùng path override cho tới khi có thông báo re-publish".

## 2. [HIGH] Native dependency override mâu thuẫn với khai báo của chính SDK — rủi ro "không build được out-of-the-box"

`pubspec.yaml` host, `dependency_overrides`:

```yaml
applovin_max: 4.6.0
google_mobile_ads: 6.0.0
gma_mediation_applovin: 2.5.1
```

nhưng `packages/ad_sdk/pubspec.yaml` khai báo:

```yaml
google_mobile_ads: ^7.0.0
applovin_max: ^4.6.4
```

Comment tại chỗ override giải thích rõ: bản `applovin_max ^4.6.4` kéo `AppLovinSDK 13.6.1`/`gma_mediation_applovin` mới hơn → **xung đột CocoaPods** trên iOS. Nghĩa là: **nếu một đối tác mới thêm package này vào app của họ đúng như package tự khai báo (không biết cần override), build iOS sẽ vỡ ngay từ đầu.** Đây không phải lỗi lý thuyết — nó đã xảy ra thật với chính team này (comment ghi rõ lý do 1.0.18 từng vỡ) và giải pháp hiện tại là ghim cứng 3 version cũ hơn ở tầng consumer, không phải sửa trong bản thân package.

Với một team đối tác chỉ đọc README/pubspec của package (không đọc code của app mẫu này), thông tin "bạn cần 3 dòng `dependency_overrides` này để build được" **không nằm ở đâu trong `packages/ad_sdk/README.md` hay `pubspec.yaml` của package** — nó chỉ tồn tại như comment trong app tiêu thụ. Đây là gap tài liệu hoá nghiêm trọng cho một SDK định vị "drop in, ship" (README tự mô tả).

**Khuyến nghị:** hạ constraint trong `packages/ad_sdk/pubspec.yaml` xuống đúng version đã verify chạy được (`google_mobile_ads: ^6.0.0`, `applovin_max: 4.6.0`) thay vì khai `^7.0.0`/`^4.6.4` rồi bắt consumer tự override ngược lại — hoặc, nếu quyết định giữ version mới hơn, xác nhận lại xem xung đột pod còn tồn tại (bản `gma_mediation_applovin`/`applovin_max` có thể đã fix từ lúc ghi comment) và cập nhật cả hai đồng bộ.

**Retest 2026-07-10:** thử nâng `applovin_max` → `4.6.4` + `gma_mediation_applovin` → `2.6.1` (bản mới nhất upstream, để khớp đúng constraint SDK tự khai) — **fail ngay ở `flutter pub get`**, chưa tới lượt CocoaPods: `gma_mediation_applovin >=2.6.0` đòi `meta ^1.17.0`, còn `flutter_test` từ Flutter SDK 3.35.1 (pin trong CI, `.github/workflows/test.yml`) ép `meta 1.16.0` — xung đột version-solve ở tầng Dart, không phải native. Đã revert về bộ ghim cũ (`applovin_max 4.6.0` / `google_mobile_ads 6.0.0` / `gma_mediation_applovin 2.5.1`), `flutter pub get` lại sạch. Kết luận: **vẫn blocked upstream**, chưa unblock được bằng cách bump version — cần Flutter SDK nâng lên bản có `meta ^1.17.0`, hoặc chờ `gma_mediation_applovin` hạ constraint `meta`, trước khi retest lại (xem thêm mục 3 — lịch review định kỳ).

## 3. [MEDIUM] Native ad SDK majors đang ghim khá cũ — rủi ro drift theo thời gian, không có cadence refresh

Bundle thật đang chạy: `AppLovinSDK 13.5.0` (qua `applovin_max 4.6.0`), `google_mobile_ads 6.0.0`. Google/AppLovin định kỳ deprecate SDK major cũ (đặc biệt AdMob hay siết version tối thiểu cho Play Console mỗi 1-2 năm, và cả 2 network thường xuyên đẩy fix SKAdNetwork/ATT/privacy manifest theo OS mới). Không thấy cơ chế/checklist nào (`doc/` hoặc CI) nhắc "recheck native SDK major mỗi quý" — điều này **đã được README đề cập ở đúng 1 chỗ** (`SKAdNetworkItems ... recheck quarterly`) nhưng chỉ cho SKAdNetwork, không cho bản thân SDK major.

**Khuyến nghị:** thêm 1 dòng trong `doc/feature.md` hoặc `doc/task/README.md`: lịch định kỳ (vd mỗi quý) kiểm tra xem override ở mục 2 có thể gỡ bỏ chưa (tức là `gma_mediation_applovin`/`applovin_max` upstream đã hết xung đột pod), việc này vừa dọn nợ kỹ thuật vừa giảm rủi ro bị Play Console/App Store gắn cờ SDK lỗi thời.

## 4. [MEDIUM] Vận hành vẫn treo: GDPR/UMP form chưa publish — verify lại vẫn đúng

Kiểm tra `doc/UMP_SETUP.md` (không chỉ đọc `feature.md`): log thật vẫn ghi `requestConsentInfoUpdate failed: ... no form(s) configured` cho app ID `ca-app-pub-3612191981543807~9731053733`. Đây là **blocker thật, không phải code** — đã audit trước, xác nhận lại **vẫn đang mở** tại thời điểm round này (2026-07-10). Với một đối tác coi đây là "app mẫu để nhân bản", điểm quan trọng cần hiểu: **mỗi app con dùng SDK này sẽ cần app ID AdMob riêng và phải tự publish UMP message riêng** — đây không phải việc làm một lần cho cả SDK, mà là việc lặp lại cho từng app/từng app ID. README/MIGRATION nên nêu rõ điều này như một bước bắt buộc trong "Quick start", không chỉ nằm trong file riêng `doc/UMP_SETUP.md` của app mẫu.

## 5. [LOW–MEDIUM] Rủi ro tích hợp (business), không phải bug — cần đối tác chấp nhận tường minh

Các điểm này đã là **quyết định thiết kế có chủ đích** (do yêu cầu "VIP by code, không server" — REQ 5), không phải lỗi, nhưng một partner-lead cần list rõ để ký nhận rủi ro trước khi ship:

- **VIP/ad-cap state là local-only, không chữ ký trên Android.** `AdPreferences` (SharedPreferences) lưu plaintext cả VIP entries lẫn bộ đếm safety cap (session/hour/day). Trên thiết bị root, user có thể sửa trực tiếp file XML để tự cấp VIP hoặc reset cap quảng cáo. iOS có thêm lớp Keychain cho riêng signed-key replay (mục ledger mới), nhưng **safety cap counters** (không phải VIP key) thì cả 2 platform đều thuần local, không có bảo vệ tương đương. Đây là đánh đổi hợp lý cho yêu cầu "không server", nhưng là **revenue-integrity risk** (không phải compliance risk) mà đối tác cần biết: người dùng am hiểu kỹ thuật có thể tự vô hiu hoá toàn bộ safety layer.
- **Không có test nào chạm tới ad network thật.** 428+76 = 504 test unit/widget là tín hiệu chất lượng tốt, nhưng toàn bộ mock provider ở tầng adapter interface — không test nào gọi AdMob/AppLovin SDK thật. Rủi ro về fill-rate thật, crash native, hay thay đổi API bất ngờ từ 2 network chỉ lộ ra qua **test thủ công trên thiết bị thật** (đã có nhiều lần verify device trong lịch sử `feature.md`, tốt) — nhưng không có cadence/checklist chính thức hoá việc này thành quy trình bắt buộc trước mỗi release, hiện phụ thuộc vào kỷ luật cá nhân.
- **Bus factor / không phải SDK chính chủ.** Đây là wrapper tự viết (MIT license, tác giả cá nhân trên GitHub `royt93`), không phải sản phẩm được AppLovin/Google support chính thức. Tên package `applovin_admob_sdk` dễ khiến người mới lướt qua pub.dev hiểu nhầm là SDK chính chủ của AppLovin. Khuyến nghị thêm 1 dòng disclaimer đầu README: "Third-party wrapper, không liên kết chính thức với AppLovin/Google."

## 6. Điểm cộng đáng ghi nhận (so với mặt bằng chung SDK wrapper tự viết)

- Kỷ luật audit hiếm gặp: 3 round độc lập + hơn chục lượt re-audit theo từng mục (`doc/task/README.md`), mọi finding đều map tới task cụ thể, có test đi kèm, không có task nào "done" mà thiếu test xanh.
- Thiết kế fail-open nhất quán cho mọi lớp chống gian lận/replay (ledger, guard) — ưu tiên đúng: không bao giờ khoá nhầm người dùng hợp lệ vì lỗi storage.
- Compliance code-side (GDPR/CCPA/COPPA/ATT) đã đúng chuẩn theo cả 3 round trước; các gap còn lại đều là vận hành (publish form trên dashboard), không phải code.

## 7. Tổng kết ưu tiên cho đối tác

| # | Vấn đề | Loại | Mức | Việc cần làm trước khi 1 app khác import SDK này |
|---|---|---|---|---|
| 1 | pub.dev stale vs local path | Packaging | CRITICAL | Bump version thật + publish, hoặc README cảnh báo rõ dùng path override |
| 2 | Override native version mâu thuẫn khai báo package | DX/Build | HIGH | Đồng bộ constraint trong `packages/ad_sdk/pubspec.yaml` với version đã verify chạy được |
| 3 | Native SDK major cũ, không cadence refresh | Nợ kỹ thuật | MEDIUM | Thêm lịch review định kỳ (quý) |
| 4 | UMP form phải publish **lại cho từng app ID mới** | Vận hành/pháp lý | MEDIUM | Nêu rõ trong Quick Start, không chỉ file riêng |
| 5 | Local-only cap/VIP integrity, không test ad thật, bus factor | Business risk chấp nhận được | LOW–MEDIUM | Ký nhận rủi ro tường minh, không cần fix code |
