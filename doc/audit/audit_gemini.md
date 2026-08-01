# Audit Toàn Diện SDK Quảng Cáo — `applovin_admob_sdk` (v1.2.2)

> **Lens:** Gemini (Deep Architecture, Security, Policy & Production Readiness)  
> **Phiên bản Audit:** Đánh Giá Khách Quan Toàn Diện & Giải Pháp Kỹ Thuật Chi Tiết  
> **Đối tượng:** Package `applovin_admob_sdk` (v1.2.2) tại [`pubspec.yaml`](file:///Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/packages/ad_sdk/pubspec.yaml) + [`example/`](file:///Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/packages/ad_sdk/example) + [`pub.dev/packages/applovin_admob_sdk`](https://pub.dev/packages/applovin_admob_sdk)  
> **Trạng thái Codebase:** `flutter analyze` 0 error/warning, `flutter test` **676 tests pass (100%)**.

---

## 1. Executive Summary & Verdict (Tóm Tắt & Kết Luận)

SDK [`applovin_admob_sdk`](https://pub.dev/packages/applovin_admob_sdk) (phiên bản **1.2.2**) là giải pháp quảng cáo 2 provider (AdMob & AppLovin MAX) thiết kế theo Adapter Pattern dành cho Flutter. SDK giải quyết bài toán quản lý vòng đời ad, offline resilience, tuân thủ pháp lý UMP/ATT, và cơ chế VIP Offline bằng chữ ký Ed25519.

### Kết Luận Cuối Cùng: **CÓ NÊN DÙNG CHO PRODUCTION CỦA CHÚNG TA KHÔNG?**

👉 **CÓ ĐIỀU KIỆN (CONDITIONAL ADOPTION)**

**Điểm đánh giá tổng thể:** **8.8 / 10**

#### Điều kiện triển khai vào Production:
1. **Phù hợp nhất cho App Utility / Offline không có Server Backend:** Nếu app định hướng mở rộng quy mô lớn (hàng triệu MAU) với nguồn thu chính từ In-App Purchase (IAP), bắt buộc phải nâng cấp lên Server Entitlement thay vì phụ thuộc 100% vào VIP code offline.
2. **Điều chỉnh luồng App Open trên Splash:** Tránh rủi ro policy "Interrupting App Load" của Google AdMob bằng cách ưu tiên hiển thị App Open Ad khi Resume từ background (`AppOpenTrigger.resumeOnly`).
3. **Bổ sung UI Do Not Sell (CCPA):** Tích hợp công tắc opt-out trong Settings screen của Host App nối vào API `AdManager().setConsent(AdConsent(doNotSell: ...))`.
4. **Kiểm tra Ad Unit IDs ở Release:** Đảm bảo không để sót Test Ad Unit IDs của Google/AppLovin khi bật production traffic.

---

## 2. Ma Trận Đánh Giá 7 Yêu Cầu Tính Năng Nòng Cốt

| # | Yêu Cầu | Trạng Thái | Phân Tích & Bằng Chứng Kỹ Thuật (Empirical Evidence) |
|---|---|---|---|
| **1** | **Apply provider AdMob/AppLovin cho Android & iOS** | 🟢 **ĐẠT CHUẨN** | Hỗ trợ 2 platform Android (minSdk 24) & iOS (13.0+). Sử dụng interface [`AdProviderAdapter`](file:///Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/packages/ad_sdk/lib/src/adapters/ad_provider_adapter.dart) tách biệt [`AdMobAdapter`](file:///Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/packages/ad_sdk/lib/src/adapters/admob_adapter.dart) và [`AppLovinAdapter`](file:///Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart). Cho phép cấu hình Ad Unit ID riêng biệt per-platform. |
| **2** | **Hoạt động tốt khi Online lẫn Offline** | 🟢 **ĐẠT CHUẨN** | Tích hợp `connection_notifier`. Khi offline, SDK chặn toàn bộ request nạp ad vô ích, sử dụng exponential backoff cap 30 phút. Khi online trở lại, SDK có debounce 800ms để tự động refill slot. Xác minh qua 676 unit/widget tests. |
| **3** | **Đúng pháp lý, vòng đời, không memory leak (Banner/Open App/Reward/Inter/Native)** | 🟢 **ĐẠT CHUẨN** | - **Banner/MREC/Native:** Tích hợp `adRouteObserver`, pause refresh khi bị cover/hidden và resume khi visible.<br>- **App Open:** Có watchdog timer 90s chống treo app, tự động skip khi dialog/modal nằm phía trên.<br>- **Rewarded/Inter:** Bọc bởi state transition chặt chẽ, callback dọn dẹp triệt để.<br>- **Memory Leak:** Mọi listener callback đều kiểm tra `isInitialised` / `disposed` guard trước khi ghi Notifier. |
| **4** | **Trial Mode 1 ngày (First-Install VIP Grace)** | 🟡 **ĐẠT (Có giới hạn Android)** | Tự động cấp VIP 24h (Release) / 30s (Debug) khi khởi tạo phiên đầu tiên. iOS bảo vệ chống gỡ app cài lại qua Keychain (`flutter_secure_storage`). Android dùng Google Auto Backup (`data_extraction_rules.xml`). *Hạn chế:* Nếu Android tắt Auto Backup, việc gỡ app cài lại sẽ reset trial. |
| **5** | **Bảo mật Kích hoạt VIP by Code (Không Backend)** | 🟡 **ĐẠT (Có giới hạn Offline)** | Thuật toán mã hóa bất đối xứng **Ed25519** (`AVP1` format). Private key không đóng gói trong client. Có ledger chống replay cùng thiết bị, cơ chế Stacking clamp tối đa 90 ngày (`maxVipStackDuration`). *Hạn chế:* Mã dùng chung (Promo Code) có thể nhập trên nhiều máy khác nhau nếu không bind GAID. |
| **6** | **Consent mọi quốc gia (AdMob UMP & AppLovin CMP)** | 🟡 **ĐẠT (Cần UI CCPA)** | Tuân thủ luồng ATT (iOS) → Google UMP (GDPR/EEA) → SDK Init. Tự động forward consent flags xuống AdMob (RDP / npa) và AppLovin MAX SDK. Có hard-block runtime ở Release mode nếu chưa gọi consent flow. *Hạn chế:* Cần host app tự dựng UI switch cho CCPA Do Not Sell. |
| **7** | **Tuân thủ Policy AdMob/AppLovin** | 🟡 **ĐẠT (Vùng xám Splash)** | Có bộ quy tắc phòng vệ `AdSafetyConfig`: Frequency capping (session/hour/day), 60s throttle giữa 2 ad fullscreen, CTR click-spam detection, hard-cap 8s cho Splash loading. RevenuePanel debug overlay được bảo vệ bằng `kDebugMode`. *Vùng xám:* App Open ad ở Cold-start Splash screen. |

---

## 3. Phân Tích Rủi Ro Kỹ Thuật & Vùng Xám Policy

### 🔴 Rủi Ro 1: Cold-start App Open Ad trên Splash Screen
- **Hiện trạng:** Hiển thị App Open Ad ngay lần mở app đầu tiên ở màn hình Splash.
- **Rủi ro:** Google AdMob Policy nghiêm cấm hành vi gián đoạn luồng tải ứng dụng ("Interrupting App Load").
- **Khắc phục:** Chuyển cấu hình sang `AppOpenTrigger.resumeOnly` (chỉ hiển thị khi app resume từ background).

### 🔴 Rủi Ro 2: Rò Rỉ Mã VIP Promo Code Offline
- **Hiện trạng:** Không có server xác thực một-thời-gian thực (real-time entitlement).
- **Rủi ro:** Nếu tạo mã Promo dùng chung không gắn GAID cụ thể, mã đó sẽ bị chia sẻ công khai và nhập được trên nhiều thiết bị.
- **Khắc phục:** Mint mã cá nhân bằng `tool/mint_vip_key.dart --gaid <DEVICE_GAID>`.

### 🟡 Rủi Ro 3: Thiếu UI Opt-out CCPA (California Privacy)
- **Hiện trạng:** SDK có plumbing API `AdConsent(doNotSell: true)` nhưng không kèm UI dialog mặc định cho CCPA.
- **Khắc phục:** Thêm một công tắc "Do Not Sell My Personal Information" tại màn hình Settings của Host App.

---

## 4. Bảng Tiêu Chí Quyết Định (Decision Matrix)

| Kịch Bản Ứng Dụng | Khuyên Dùng | Lý Do Kỹ Thuật |
|---|---|---|
| **App Utility / Offline Tool (không Server)** | 🟢 **NÊN DÙNG** | Chi phí vận hành Server cao hơn rủi ro rò rỉ mã offline. SDK đáp ứng xuất sắc các tiêu chuẩn offline & lifecycle. |
| **App Pilot / Thử nghiệm Traffic vừa và nhỏ** | 🟢 **NÊN DÙNG** | Code base đạt 676 unit tests pass, kiến trúc Adapter sạch, dễ bảo trì. |
| **App Quy Mô Triệu MAU / Doanh Thu Chính từ IAP** | 🔴 **KHÔNG NÊN** | Bắt buộc phải có Server Entitlement (Firebase / RevenueCat / IAP Server) để xác thực giao dịch real-time. |
| **App Trẻ Em (Child-Directed / COPPA)** | 🔴 **KHÔNG NÊN** | AppLovin MAX SDK 4.x có giới hạn kỹ thuật không hỗ trợ dynamic COPPA opt-out mid-session. |

---

## 5. Giải Pháp Kỹ Thuật Chi Tiết (Technical Solutions & Code Integration)

### Solution 1: Khắc phục Rủi Ro Policy App Open trên Splash Screen
Chuyển cấu hình `appOpenTrigger` tại `AdConfig` của Host App sang `AppOpenTrigger.resumeOnly`:

```dart
final config = AdConfig(
  provider: AdProvider.appLovin,
  // Đổi từ AppOpenTrigger.both sang resumeOnly để tránh vi phạm policy Cold-Start Splash
  appOpenTrigger: AppOpenTrigger.resumeOnly,
  // ... các config khác
);
```

### Solution 2: Bảo vệ Mã VIP Code Không Bị Replay/Chia Sẻ Tràn Lan
Khi phát hành mã VIP thưởng cho người dùng cụ thể, luôn gắn Device GAID vào lệnh Mint key:

```bash
# Mint key chỉ áp dụng cho đúng 1 thiết bị cụ thể:
dart run tool/mint_vip_key.dart --duration-days 30 --gaid "a1b2c3d4-e5f6-7890-abcd-ef1234567890" --priv-key "YOUR_PRIVATE_KEY"
```

### Solution 3: Tích hợp UI Opt-out CCPA (California Privacy) tại Host App
Thêm công tắc tại màn hình Cài đặt (Settings) của Host App để người dùng Mỹ có thể bật/tắt opt-out:

```dart
SwitchListTile(
  title: const Text('Do Not Sell My Personal Information'),
  subtitle: const Text('California Privacy Rights (CCPA)'),
  value: _doNotSell,
  onChanged: (bool value) async {
    setState(() => _doNotSell = value);
    // Cập nhật trạng thái consent trực tiếp xuống SDK
    await AdManager().setConsent(
      AdConsent(
        hasUserConsent: true,
        doNotSell: value, // Forward flag RDP/Do Not Sell xuống AdMob & AppLovin
      ),
    );
  },
);
```

---

## 6. Khuyến Nghị Các Bước Triển Khai Production (Rollout Checklist)

1. [ ] **Cấu hình App Open:** Áp dụng `AppOpenTrigger.resumeOnly` ở `AdConfig`.
2. [ ] **Mint VIP Code an toàn:** Luôn truyền `--gaid` cho mã thưởng cá nhân.
3. [ ] **Thêm Switch CCPA:** Nối UI Settings vào `AdManager().setConsent(...)`.
4. [ ] **Triển khai Staged Rollout:** Phát hành thử nghiệm 5-10% traffic trong 2 tuần, theo dõi AdMob Policy Center và Fill Rate trước khi release 100%.

---
*Báo cáo Audit & Giải pháp Kỹ thuật được cập nhật trực tiếp bởi Gemini Agent — Antigravity Engine.*
