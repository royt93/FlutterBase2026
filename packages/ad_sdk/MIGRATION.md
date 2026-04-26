# Migration Guide

## 🆕 1.0.14 → 1.0.15 — Không cần đổi gì

**Không có breaking change.** Update version, chạy `flutter pub get`, xong.

```yaml
dependencies:
  applovin_admob_sdk: ^1.0.15
```

```bash
flutter pub get
```

### Cảnh báo cho user đã có code

⚠️ **Kiểm tra `android/app/src/main/AndroidManifest.xml`** — nếu MainActivity có dòng `android:taskAffinity=""`, hãy **xóa nó đi**. Dòng này (Flutter create template default) gây crash khi user background app trong lúc xem ad. Đã giải thích chi tiết ở `README.md` → "Pitfalls".

```diff
  <activity
      android:name=".MainActivity"
      android:exported="true"
      android:launchMode="singleTop"
-     android:taskAffinity=""        <!-- XÓA dòng này -->
      ...
```

### Tận dụng feature mới (optional)

#### A. Cupertino consent dialog (default ON)

Nếu app cũ của bạn đã có UMP form riêng, **tắt** auto-show:

```dart
AdConfig(
  autoShowConsentDialog: false,  // dùng UMP form của riêng bạn
  // ...
)
```

Nếu chưa có, để default — SDK auto-show ~1s sau splash. Tiếng Việt:

```dart
AdConfig(
  consentDialogStrings: ConsentDialogStrings.vi,
  // ...
)
```

#### B. First-install VIP grace 24h

Default ON cho release builds. Tắt nếu không muốn:

```dart
AdConfig(
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  // ...
)
```

Hoặc tùy chỉnh duration:

```dart
AdConfig(
  firstInstallVipGrace: const FirstInstallVipGrace(Duration(hours: 12)),
  // ...
)
```

#### C. Google UMP wrapper

Nếu app target EEA users:

```dart
// Trong splash, TRƯỚC AdManager().initialize:
final r = await AdManager().requestUmpConsent(
  testMode: kDebugMode,
);
if (!r.canRequestAds) return;  // user denied
// ... tiếp tục init
```

---

## 🔄 1.x → 2.x (older)

> Phần này dành cho user upgrade từ phiên bản 1.x cũ. Nếu bạn đã ở 1.0.14, chỉ cần xem section trên.

### 1. Update import

```diff
- import 'package:applovin_admob_sdk/ad_sdk.dart';
+ import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
```

### 2. Logger configuration

```diff
- SafeLogger.setEnabled(true);
+ // Cấu hình tự động qua AdConfig.logLevel
```

```dart
AdConfig(
  logLevel: AdLogLevel.warning,
  logTagFilter: ['AdManager', 'AdSafety'],
  onLog: (lvl, tag, msg) => Sentry.captureMessage('[$tag] $msg'),
);
```

### 3. VIP API (breaking)

#### 1.x (cũ)
```dart
AdManager().addVIPMember(['gaid-1', 'gaid-2']);
final isVip = AdManager().isVIPMember();
```

#### 2.x / 1.0.15 (mới)
```dart
// Programmatic add (cho purchase flow)
await AdManager().vip!.addVip(
  key: 'PURCHASED_PREMIUM_${transactionId}',
  duration: const Duration(days: 365),
);

// Cupertino dialog redeem (cho user nhập key)
await AdManager().vip!.redeemVip(
  context,
  key: userInput,
  duration: const Duration(days: 30),
  validator: (key) => myServer.verifyVip(key),
  strings: AdConfig.instance.vipDialogStrings,
);

// Check
if (AdManager().vip!.isActive) { /* VIP */ }

// Reactive UI
ValueListenableBuilder<bool>(
  valueListenable: AdManager().vip!.activeListenable,
  builder: (_, active, __) => active ? VipBadge() : SizedBox.shrink(),
)
```

**Auto-migration**: 1.x GAID list được tự động convert sang VipEntry (year-2099 expiry) trên init đầu tiên — **bạn không cần làm gì**. Code cũ vẫn chạy, chỉ là deprecated.

### 4. Replace `setState` / `late` / `!`

Theo project policy, SDK code đã loại bỏ hết `late` / `!` / `setState`. Nếu app code của bạn extend `BaseStatefulState`, cập nhật theo:

```diff
- late final Foo foo;
- @override void initState() { foo = Foo(); }
+ Foo? foo;  // nullable
+ @override void initState() { foo = Foo(); }
+ // dùng foo! → foo?.method() hoặc final f = foo; if (f != null) f.method();
```

---

## ❓ FAQ

### Có cần update gì ở native code không?

**Android**: Xóa `android:taskAffinity=""` (xem trên).

**iOS**: Không cần thay đổi nào nếu đã có `SKAdNetworkItems`, `NSUserTrackingUsageDescription`, `AppLovinSdkKey`, `GADApplicationIdentifier`.

### Code cũ có còn chạy không?

**Có**. Mọi method 1.x cũ đều deprecated chứ chưa removed. Sẽ remove ở 3.0. Bạn có thời gian để migrate dần dần.

### Test grace 24h như thế nào trong dev?

Default `FirstInstallVipGrace.auto` đã handle: trong debug build dùng 30s thay vì 24h. Wipe app data, run app, đợi 30s là VIP hết.

```bash
adb shell pm clear your.package.name
flutter run
```

### Ad không hiện sau dismiss inter — bị "ad not ready"?

Lỗi 1.x cũ. 1.0.15 đã fix bằng:
- Slot watcher track dismiss timestamp đúng lúc thật sự dismiss (không phải lúc reward earned)
- `_lastFullscreenDismissAt` armed correctly → guard window 5s sau dismiss

Nếu vẫn gặp ở 1.0.15, mở issue + paste log có prefix `roy93~`.

### Memory pressure log fire nhiều quá

1.0.15 đã throttle 60s/event. Nếu vẫn nhiều, có thể app của bạn thật sự đang chịu pressure — thử reduce ad preload song song.

---

## 🆘 Vẫn gặp vấn đề?

1. Xem `README.md` → "Pitfalls"
2. Run với `AdConfig.logLevel = AdLogLevel.verbose` để có full log `roy93~ [Tag]`
3. Mở issue ở [GitHub](https://github.com/royt93/FlutterBase2025/issues) kèm log + version + provider (admob/applovin)
