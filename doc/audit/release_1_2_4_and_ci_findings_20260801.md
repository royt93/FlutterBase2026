# Phát hành 1.2.3 + 1.2.4, sửa CI đỏ, đồng bộ plugin native (2026-08-01)

> **Cập nhật 2026-08-02 — hai kết luận trong bản đầu đã sai, xem mục 10.**
> Mục 5 nói fix `consent_country_demo_test` đã xong: **chưa**, nó vẫn đỏ trên CI
> vì một nguyên nhân thứ hai. Mục 6 nói flake iOS chỉ có một loại: **có hai**.
> Các mục dưới giữ nguyên như đã viết; phần đính chính nằm ở cuối.

**Người thực hiện:** Claude (Opus 5), phiên làm việc liên tục cùng user.
**Cách làm:** mọi kết luận dưới đây đều reproduce được — chạy thật trên iPhone 17 Pro Simulator + máy Android thật (TECNO BG6, API 33), hoặc đọc log CI/`pubspec.lock` thật. Chỗ nào là giả thuyết chưa chứng minh thì ghi rõ.

Tài liệu này **sửa lại finding #2 của `audit_partner_lead_20260710.md`** — xem mục 4.

## 0. Tóm tắt

| Việc | Kết quả |
|---|---|
| pub.dev score | **130/160 → 150/160** |
| Version phát hành | 1.2.3 rồi 1.2.4 (1.2.4 chỉ là metadata) |
| CI | từ đỏ 3 run liền → xanh, rồi cô lập + retry cho flake iOS |
| 2 test integration đỏ | sửa đúng root cause, không nới timeout |
| Host ↔ SDK | host từ `google_mobile_ads 6.0.0` lên **7.0.0**, khớp `^7.0.0` SDK khai |
| Bug portability | xoá `org.gradle.java.home` hardcode trong file tracked |

Commit: `77fd107`, `788fc49`, `2007944`, `ece5c5c`, `6d927c2`, `7a5287d`.

## 1. Hai giới hạn độ dài description của pub.dev — `--dry-run` KHÔNG bắt được

Đây là thứ đã làm 2 lần `flutter pub publish` đầu tiên thất bại, dù `--dry-run` báo **"Package has 0 warnings"** ngay trước đó.

| Tầng | Giới hạn | Hậu quả khi vượt |
|---|---|---|
| Upload API | **200** ký tự | Từ chối thẳng, chặn upload: `Message from server: Screenshot description for doc/screenshots/03_safety_status.png is too long (over 200 characters)` |
| pana (tính điểm) | **160** ký tự | Upload vẫn qua, nhưng **mất 10 điểm** ở "Provide a valid pubspec.yaml" và **10 điểm nữa** ở "Package has an example and has no issues with screenshots" |

1.2.3 lên với `description` 197 ký tự và screenshot 187/195/194 — đều dưới 200 nên upload thành công, nhưng chính vì trên 160 mà score đứng ở 130/160. 1.2.4 rút xuống 145/145/143/139 → 150/160.

Giới hạn 160 áp cho **cả** `description` của package, không chỉ screenshot. Đã ghi chú cạnh field trong `packages/ad_sdk/pubspec.yaml`.

## 2. Độ trễ CDN sau khi publish

Sau khi upload thành công, `flutter pub get` vẫn báo `Because saigonphantomlabs depends on applovin_admob_sdk ^1.2.3 which doesn't match any versions` trong khoảng 1–3 phút, **trong khi** `https://pub.dev/api/packages/applovin_admob_sdk` đã trả `latest=1.2.3`. API đã cập nhật còn CDN edge còn cache listing cũ.

Với 1.2.4 phải thử **7 lần** mới resolve được. `pub cache clean` không liên quan — chỉ cần chờ và thử lại.

## 3. Breakdown 150/160 — 10 điểm cuối nằm ở đâu

```
Follow Dart file conventions        30/30  ✓
Provide documentation              20/20  ✓  (dartdoc 407/737 = 55.2%)
Platform support                   20/20  ✓  (Android + iOS)
Pass static analysis               50/50  ✓
Support up-to-date dependencies    30/40  ← 0/10: "All of the package
                                             dependencies are supported in
                                             the latest version"
```

`dart format` trên toàn package (8 file bẩn, trong đó 4 file `lib/`) là thứ mở lại điểm ở mục static analysis. `repository`/`homepage`/`issue_tracker`/`topics`/`platforms` được thêm mới — tag xác nhận đã ăn: `has:topic`, `topic:ads|admob|applovin|monetization|mediation`, `platform:android`, `platform:ios`, `license:osi-approved`.

## 4. SỬA LẠI finding #2 của `audit_partner_lead_20260710.md` — nghẽn không phải `meta`

Ghi chú cũ trong `pubspec.yaml` host kết luận: không nâng được `gma_mediation_applovin` vì `>=2.6.0` đòi `meta ^1.17.0` mà `flutter_test` của Flutter 3.35.1 ép `meta 1.16.0`.

**Đúng cho 2.6.x, nhưng lần đó nhảy thẳng 2.5.1 → 2.6.1 và bỏ qua 2.5.2.** Metadata thật trên pub.dev:

```
2.5.1: flutter >=3.27.0, google_mobile_ads ^6.0.0
2.5.2: flutter >=3.35.1, google_mobile_ads ^7.0.0        ← không đòi meta ^1.17.0
2.6.0: flutter >=3.38.1, google_mobile_ads ^8.0.0, meta ^1.17.0
2.6.2: flutter >=3.38.1, google_mobile_ads ^9.0.0, meta ^1.17.0
```

Hệ quả của việc bỏ qua 2.5.2: `dependency_overrides` phải ghim `google_mobile_ads: 6.0.0` (vì 2.5.1 đòi `^6.0.0`), nên **app ship trên plugin native thấp hơn 1 major so với thứ SDK khai và test**. 675 unit test + 23 integration test của SDK đều resolve GMA 7.0.0; app thật chạy 6.0.0. Override làm version solver im lặng hoàn toàn — chỉ đọc `pubspec.lock` mới thấy.

Đã sửa: dùng 2.5.2, bỏ override `google_mobile_ads`. Host giờ resolve 7.0.0, pod `Google-Mobile-Ads-SDK` từ 12.2.0 lên **12.14.0**.

### 4.1 Tường thật cho `applovin_max` nằm ở CocoaPods, không phải Dart

```
applovin_max 4.6.4            → AppLovinSDK (= 13.6.3)
gma_mediation_applovin 2.5.2  → GoogleMobileAdsMediationAppLovin (~> 13.5.0.0)
                                  → AppLovinSDK (= 13.5.0)
```

Hai bên ghim **chính xác** hai version AppLovinSDK khác nhau nên `pod install` không giải được. Vì vậy `applovin_max` vẫn phải override xuống 4.6.0 dù SDK khai `^4.6.4`.

**Bài học vận hành:** `flutter pub get` xanh **không chứng minh gì** về pod graph. Mọi thay đổi ở 3 package này phải kiểm bằng `pub get` **và** `cd ios && pod install` **và** build thật cả 2 nền tảng.

Tổ hợp cuối (`google_mobile_ads 7.0.0` + `gma_mediation_applovin 2.5.2` + `applovin_max 4.6.0`) đã nghiệm thu đủ 5 lớp cục bộ — `pub get`, `flutter analyze`, 79/79 host test, `pod install`, `flutter build apk --target-platform android-arm64`, `flutter build ios --simulator` — và CI run `30707281153` **xanh cả 4 job** (host 2m5s, sdk 2m32s, Android emulator 25m52s, iOS Simulator 27m53s).

### 4.2 GMA 8/9 bị chặn bởi sàn Flutter, không phải bởi `meta`

```
$ (đổi tạm google_mobile_ads: ^9.0.0 rồi flutter pub get)
Because applovin_admob_sdk depends on google_mobile_ads >=8.0.0
which requires SDK version >=3.10.0 <4.0.0, version solving failed.
```

GMA **8 và 9** đều đòi Dart `>=3.10.0` + Flutter `>=3.38.1`. Repo pin Flutter 3.35.1 (Dart 3.9.x), cả local lẫn CI. Nâng lên cũng buộc nâng sàn `environment` của `packages/ad_sdk` → **breaking cho consumer**, tức 2.0.0 chứ không phải 1.3.0.

Nên 10 điểm pub.dev cuối phụ thuộc **quyết định nâng Flutter**, không phải một lần bump dependency.

## 5. Hai test integration đỏ — hai root cause khác nhau

CI đỏ 3 run liền, mỗi job integration hụt đúng 1 test, và **khác nhau theo nền tảng**:

```
Android emulator: vip_redeem_flow_test      — Found 0 widgets with text "VIP ACTIVE"
iOS Simulator:    consent_country_demo_test — Expected: 'DE'  Actual: <null>
```

### 5.1 Pump thời lượng cố định đua với ghi async qua platform channel

Cả 2 test đều `tap(...)` rồi `pump(300ms)` rồi assert. Số đo thật bằng instrumentation:

| Hiệu ứng | Android | iOS Simulator |
|---|---|---|
| `ConsentManager.set()` áp dụng | ngay frame kế | ~300–600 ms |
| VIP redeem áp dụng | ~2.3 s | < 300 ms |
| SnackBar được build | **không** ở frame ngay sau tap | tương tự |

300 ms nằm đúng ranh giới → nền tảng nào chậm hơn thì test đó đỏ. Đã thay bằng poll có chặn trên. Với consent còn poll cả SnackBar và card re-render, cap 3 s để không vượt 4 s auto-dismiss của chính SnackBar.

Giả thuyết đầu tiên (hero card bị `ListView` lazy không build) **sai** — diag chứng minh card có trong tree và hiển thị `VIP NOT ACTIVE`, `isVIPMember=false` ở mốc 300 ms, rồi cả hai đổi ở mốc 2.3 s.

Cảnh báo `derived an Offset that would not hit test` trên iOS chỉ là nhiễu: `enterText` mở bàn phím, `viewInsets.bottom` animate 0 → 288, nên rect finder đọc ra đã cũ lúc dispatch pointer. Thí nghiệm `tap(warnIfMissed: false)` cho `country=DE` → tap vẫn ăn. Đã unfocus và chờ inset về 0 trước khi tap.

### 5.2 `vip_redeem_flow_test` chỉ chạy được MỘT LẦN mỗi thiết bị iOS

Test mint cứng `kid: 'integration_kid'`. `VipManager.redeemSignedKey` ghi kid đã dùng vào ledger chống-replay bền — `packages/ad_sdk/lib/src/vip/vip_manager.dart:579` — và trên iOS ledger đó nằm trong **Keychain, sống sót uninstall theo thiết kế**. Lần chạy đầu đốt vĩnh viễn kid đó; mọi lần sau trả `VipRedeemStatus.alreadyUsed`.

CI không bao giờ thấy vì mỗi run một simulator mới. Nhưng nó chặn mọi lần rerun cục bộ, và chỉ lộ ra khi chạy 2 file cùng một invocation. Sửa bằng seam có sẵn của SDK: `clearRedeemedKeyLedgerForTest()`, đặt cạnh `revokeAll()`.

### 5.3 Nghiệm thu

`consent_country_demo_test` 3/3 pass trên Android và 3/3 trên iOS; `vip_redeem_flow_test` pass cả 2; chạy cùng nhau (đúng chế độ CI) 2 lần liên tiếp trên iOS; và **full 18 file trong một invocation trên iOS Simulator: 23/23 pass, 10 phút 28 giây**.

## 6. Flake launch của job iOS — đã cô lập và chặn, chưa chữa

Chữ ký, giống nhau qua nhiều run:

```
11:23:19  [AdSafety] SUSPICIOUS: CTR anomaly ...     ← file 1 xong
11:24:08  Running Xcode build... done  34.0s          ← build cho file 2
   (11:24:08 → 11:35:22: KHÔNG một dòng log nào)
11:35:22  ❌ loading app_boot_test.dart  TimeoutException after 0:12:00
11:36:20  ❌ banner_ad_test.dart  Failed to start Dart Development Service
```

App **chưa bao giờ khởi động** — không in nổi `[AdManager] 🚀 AdManager singleton CREATED`, dòng đầu tiên của cold start. Nên `tester.pump()` không hề bị chặn; lỗi báo ở pha `loading`. Kèm `Unable to terminate com.example.adSdkExample ... found nothing to terminate`. **Nới `--timeout` là vô nghĩa: chờ thêm không làm app chạy.**

Không phải rò tài nguyên: 16 file còn lại sau đó chạy ~1 phút/file, không leo dần. Và cùng 18 file pass 23/23 trên simulator cục bộ.

Hai xử lý đã áp:
1. **Cô lập** (`788fc49`): mỗi file một invocation `flutter test`. Gần như miễn phí vì log cho thấy `flutter test` đã rebuild+relaunch app giữa các file (bước Xcode ~34 s). Kết quả đo được: job từ 35m42s (đỏ) xuống **28m19s (xanh)** — bỏ được 12 phút chờ timeout vô ích, và log nêu đúng tên file: `Failed files: integration_test/fill_rate_monitor_demo_test.dart`.
2. **Retry 1 lần/file + log** (`7a5287d`): vì cô lập đã chứng minh flake là **ngẫu nhiên** chứ không gắn với test cụ thể — run `30697397657` mất `app_boot_test.dart`, run `30704574568` mất `fill_rate_monitor_demo_test.dart`. Mọi retry phát `::warning` nêu tên file, cộng dòng tổng kết `Files that needed a retry: ...`. File fail **2 lần** vẫn fail job.

Retry là **che, không phải chữa** — và đúng 2 race ở mục 5 từng đỏ/xanh xen kẽ, retry im lặng sẽ giấu mất chúng. Đó là lý do bắt buộc log.

Root cause thật (CoreSimulator/DDS trên runner GitHub) **chưa xác định**. Cục bộ không tái hiện được.

## 7. `android/gradle.properties` hardcode JDK của máy khác

```
org.gradle.java.home=/Users/loitran/Library/Java/JavaVirtualMachines/openjdk-20.0.1/Contents/Home
```

File **tracked**. Mọi máy khác fail **toàn bộ** build Android với `Value '...' given for org.gradle.java.home Gradle property is invalid (Java home supplied is invalid)` — repo không build được trên clone mới. Đã xoá; verify APK vẫn build (Gradle dùng JDK mà Flutter cấp; `JAVA_HOME` trên máy test còn chưa set).

Cùng loại với `.flutter-plugins-dependencies` bị commit kèm đường dẫn `/Users/loitran/...` — file này generated, đừng commit thay đổi của nó.

## 8. Kết luận sai của chính phiên này (ghi lại để không lặp)

- **`JetifyTransform` failed → tưởng jetifier hỏng.** Sự thật: `No space left on device`, đĩa đầy 100% (222 MiB trống / 228 GiB). Đã 2 lần kết luận nhầm trước khi đọc `Caused by`.
- **Tưởng hero card không build vì `ListView` lazy.** Sự thật: redeem chưa xong (mục 5.1).
- **Tưởng `--force` bị bỏ qua.** Sự thật: `--force` bị xuống dòng nên shell hiểu thành lệnh riêng: `(eval):2: command not found: --force`.

## 9. Việc còn mở

| | Việc | Trạng thái |
|---|---|---|
| A | Nâng Flutter `>=3.38.1` để lấy GMA 9 (10 điểm cuối) + bỏ override `applovin_max` | Chưa làm. Là quyết định semver/release (2.0.0), không phải cleanup |
| B | Thêm `concurrency` group cho workflow — 2 push cách nhau vài phút để lại 2 run 35 phút chạy đua | Chưa làm |
| C | Job Android emulator vẫn dồn 18 file vào 1 invocation, chưa có cô lập/retry — cùng hình đã làm job iOS giấu 17 file | Chưa làm. Đang xanh |
| D | Root cause flake launch iOS | Chưa. Đã chặn bằng retry + log |

Tham khảo ý kiến ngoài: codex và gemini (chạy độc lập, đọc cùng bản tóm tắt) đều xếp B và C vào top 3 và đều **chủ động hoãn A** vì cần kế hoạch thông báo consumer, hoãn **D** vì nguyên nhân gần chắc nằm ngoài repo.

---

# Đính chính và bổ sung (2026-08-02)

## 10. Mục 5 sai: fix `consent_country_demo_test` chưa xong

Run `30707984024` **xanh**, nhưng dòng `::warning` của cơ chế retry lộ ra file phải chạy lại là `consent_country_demo_test.dart` — và lần fail đầu **không phải** treo launch. Nó fail trong ~2 phút:

```
tap() ... derived an Offset (Offset(350.5, 568.0)) that would not hit test
Expected: 'DE'
  Actual: <null>
```

Fix ở mục 5.1 chỉ khử **một** nguồn dịch chuyển của nút: bàn phím mở làm Scaffold resize (`viewInsets` 0 → 288). Nhưng `scrollUntilVisible` kéo theo bước rời rạc và trả về **trong khi** cú pointer-up nó vừa gửi còn đang chạy animation ballistic của `BouncingScrollPhysics`. Trên simulator CI bàn phím **không hề lên** (`viewInsets` = 0) nên vòng chờ inset thoát ngay, chỉ còn cú fling — đúng thứ mà máy phát triển nhanh gấp ~3.4 lần không bao giờ gặp vì fling đã dừng trước khi tap đi.

### 10.1 Đây là lớp bug cả suite, không phải một file

Rà 18 file: **11 file** dùng đúng mẫu

```dart
await tester.scrollUntilVisible(target, 200, scrollable: ...);
await tester.tap(target);
```

Chỉ `consent_country_demo_test` đã **quan sát được** fail theo cách này, nhưng nó chỉ lộ trên phần cứng đủ chậm, và giờ retry đã che. Đợi từng file tự đỏ thì mỗi vòng tốn ~45 phút.

Sửa: gom phần chờ vào một extension dùng chung `scrollUntilVisibleAndSettle` (`packages/ad_sdk/example/integration_test/scroll_helpers.dart`) — cuộn xong thì pump tới khi rect của target **giống hệt nhau 3 frame liên tiếp** rồi mới trả về. Ba frame chứ không phải một, vì một lần trùng có thể rơi vào giữa hai bước của đường cong đang chạy. Mọi call site chỉ đổi tên method, nên chỗ tap nằm trong `if` (như `fill_rate_monitor_demo_test`) cũng được phủ.

Nghiệm thu: `flutter analyze` sạch, full 18 file trên iOS Simulator **23/23 pass, 10m25s**.

## 11. Mục 6 sai: có HAI loại flake, không phải một

Retry che cả hai; chỉ nhờ log `::warning` mới tách được:

| File | Lần fail đầu | Loại |
|---|---|---|
| `app_boot_test`, `fill_rate_monitor_demo_test`, `diagnostics_demo_test` | `TimeoutException after 0:12:00`, log im lặng tuyệt đối | treo launch — hạ tầng |
| `consent_country_demo_test` | assertion + tap trượt, ~2 phút | **bug thật trong test** |

Đây chính là lý do bắt buộc log mọi lần retry. Nếu retry im lặng, một run xanh đã chôn luôn một assertion fail thật giữa đám flake hạ tầng.

## 11.1 Lớp bug thứ hai cũng rải khắp suite — nhưng chỉ 2 chỗ thật sự đua

Mục 5.1 sửa "pump cố định đua với ghi async" ở 2 file bị bắt quả tang. Rà lại toàn bộ: mẫu `pump(<cố định>)` rồi `expect` xuất hiện ở **10 file**, nhưng phần lớn **không** đua gì:

- `banner_ad_test`, `mrec_ad_test`, `slot_state_panel_test` (bước reinit) — pump nằm trong vòng lặp poll sẵn rồi;
- `pump(300ms)` rồi `expect(find.text('X demo'))` chỉ chờ hết route transition, mà text đích đã có trong tree từ frame đầu.

Thu hẹp về **assertion trên state của manager** — thứ mà tap chỉ mới bắt đầu ghi — còn đúng 2 chỗ:

| Vị trí | Assertion sau tap |
|---|---|
| `consent_dialog_test:94` | `expect(AdManager().consent.hasUserConsent, ...)` sau khi tap "Apply consent to providers" |
| `slot_state_panel_test:94` | `expect(AdManager().adapter, isNull)` sau khi tap "Destroy SDK" |

Cả hai đã chuyển sang poll có chặn trên. Chỗ consent cap 3s để không vượt SnackBar ~4s mà dòng kế assert. Chỗ slot_state chỉ đang lặp lại đúng cách mà bước re-initialise ngay dưới nó **đã** làm từ trước — bước destroy là chỗ duy nhất bị bỏ sót.

Bài học: đếm số file khớp mẫu cho ra 10 và sẽ dẫn tới việc sửa 8 chỗ không hỏng. Lọc theo *thứ đang được assert* mới ra đúng 2.

## 12. Bẫy bash-vs-dash trong `android-emulator-runner`

Commit `59f16a4` chép vòng lặp retry của job iOS sang job Android, gồm cả **mảng bash**. Job chết sau 3m31s:

```
The process '/usr/bin/sh' failed with exit code 2
```

Job iOS chạy `run:` = bash trên runner GitHub; còn `android-emulator-runner` chạy `script:` bằng `/bin/sh`, tức **dash** trên Ubuntu — không có mảng. Reproduce cục bộ: `dash` trên đúng đoạn script đó trả `Syntax error: "(" unexpected`, exit 2.

Sai lầm khi kiểm: dùng `bash -n`, thứ đương nhiên chấp nhận mảng. Viết lại theo POSIX (chuỗi phân cách bằng dấu cách thay cho mảng), verify bằng dash — **và vẫn đỏ**, với thông báo khác:

```
/usr/bin/sh: 1: Syntax error: end of file unexpected (expecting "}")
```

`sh: 1:` là mấu chốt: body tới `sh` đã bị **dồn về một dòng**, nên `run_one() { ... }` trải nhiều dòng không đóng được `}`. Tức có **hai** vấn đề chồng nhau ở block `script:` này, không phải một.

Kết luận sau 2 lần hỏng: đừng viết inline nữa. Vòng lặp đã chuyển ra `.github/scripts/integration-retry.sh`, **cả job Android lẫn iOS gọi chung**, mỗi job truyền cờ `flutter test` của mình. Lợi ích quyết định: file kiểm được bằng đúng shell mà CI chạy. Đã verify `dash -n`, rồi chạy thật dưới `dash` với một `flutter` giả trên PATH — file sạch thì im lặng, fail-rồi-pass chỉ ra `::warning`, fail 2 lần ra `::error` + `Failed files (both attempts)` + exit 1, và 3 file cần người tap tay vẫn bị loại đúng.

Điểm yếu chung của cả 2 lần: **cách kiểm**. `bash -n` chấp nhận mảng, và syntax check kiểu gì cũng không nhìn thấy được vấn đề quoting chỉ tồn tại bên trong action.

## 13. B và C đã làm, `concurrency` đã nghiệm thu

- **B**: thêm `concurrency` group (`cancel-in-progress`) và `paths-ignore` cho `**.md` + `doc/**`. Quan sát được ngay: run `30729328644` chuyển sang `cancelled` khi push kế tiếp tới. Lý do có `paths-ignore`: run `30708366878` đốt 46 phút runner iOS + 25 phút Android để kiểm một commit chỉ có một file `.md`.
- **C**: job Android dùng cùng cơ chế per-file + retry có log như iOS.
- **D** (root cause treo launch): vẫn chưa xong, nhưng job iOS giờ **thu bằng chứng** khi một file phải retry — booted devices, `launchctl list`, danh sách tiến trình, và 3000 dòng cuối `CoreSimulator/<UDID>/system.log` — upload thành artifact `ios-simulator-diagnostics`. Dùng `if: always()` chứ không phải `if: failure()`, vì trường hợp cần đúng là lúc retry cứu được và job xanh. Chọn cách thu nhỏ và có mục tiêu vì `simctl diagnose` sinh hàng trăm MB mỗi lần.
