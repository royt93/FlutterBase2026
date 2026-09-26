# China Market Setup Guide (AppLovin MAX Only)

Hệ thống kiến trúc `applovin_admob_sdk` hỗ trợ thị trường Trung Quốc đại lục (Mainland China) theo cấu hình AppLovin MAX độc lập.

## 1. Nguyên tắc cốt lõi
- **Tắt AdMob hoàn toàn:** Google Mobile Ads và Google Play Services bị chặn tại Trung Quốc bởi GFW và không tồn tại trên các ROM nội địa (Huawei, Xiaomi, Oppo, Vivo).
- **Sử dụng AppLovin MAX:** Cùng 1 SDK core (`applovin_max`), không cần SDK riêng.
- **Mediation Networks:** Pangle toàn cầu không phục vụ traffic Trung Quốc nội địa; cần bổ sung **CSJ (Pangle China)** qua AppLovin Mediation Dashboard và adapter tương ứng ở consuming app.

## 2. Cấu hình SDK trong ứng dụng Flutter

Khởi tạo SDK với duy nhất provider `applovin`:

```dart
final config = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'YOUR_APPLOVIN_SDK_KEY',
    bannerId: 'YOUR_CHINA_BANNER_ID',
    interstitialId: 'YOUR_CHINA_INTERSTITIAL_ID',
    rewardedId: 'YOUR_CHINA_REWARDED_ID',
    appOpenId: 'YOUR_CHINA_APPOPEN_ID',
  ),
  // Tắt UMP consent tự động vì Google UMP phụ thuộc GMS
  autoRequestUmpConsent: false,
);

await AdManager().initialize(
  config: config,
  onComplete: (success, gaid) {
    // gaid có thể null/empty trên thiết bị không có GMS (bình thường)
  },
);
```

## 3. Checklist phát hành tại thị trường Trung Quốc
- [ ] ICP Filing (Giấy phép ICP) cho tên miền / dịch vụ trực tuyến.
- [ ] Tài khoản nhà phát triển trên các chợ ứng dụng nội địa (Huawei AppGallery, Xiaomi GetApps, Oppo App Market, Vivo App Store, Tencent MyApp).
- [ ] Đảm bảo consuming app không có dependency cứng vào GMS (`com.google.android.gms:*`).
- [ ] Thiết lập CSJ adapter trong dashboard AppLovin MAX và Gradle của host app.
