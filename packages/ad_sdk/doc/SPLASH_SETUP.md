# Splash screen setup (flutter_native_splash)

Cấu hình splash theo từng nền tảng. Nguồn chân lý: `flutter_native_splash.yaml` (repo root).

## Tham số chính

- **Màu nền chủ đạo**: `#faf9f5` — trùng `ColorConstants.appColor` (`0xfffaf9f5`).
- **iOS**: `background_image_ios: assets/images/bkg_2.png` (ảnh full màn hình).
  - ⚠️ Ảnh gốc là `bkg_2.webp`; đã convert sang PNG vì **LaunchScreen storyboard của iOS không render WebP**. Nếu đổi ảnh background, nhớ xuất PNG.
- **Android < 12**: `image_android: assets/images/ic_launcher.png` (icon tĩnh, `android_gravity: center`).
- **Android 12+**: `color #faf9f5` + `image ic_launcher_960.png` (fallback tĩnh) + **icon động** (xem dưới).
- UX: `fullscreen: true`, `android_gravity: center`.

## Gen lại native

```bash
dart run flutter_native_splash:create
```

## ⚠️ QUAN TRỌNG — icon động Android 12+ phải re-apply sau mỗi lần gen

`flutter_native_splash` **KHÔNG có** key `icon_animation`. Icon động (AnimatedVectorDrawable)
được wiring **native** trong:

- `android/app/src/main/res/values-v31/styles.xml`
- `android/app/src/main/res/values-night-v31/styles.xml`

Hai dòng cần có trong `<style name="LaunchTheme">` của **cả hai** file:

```xml
<item name="android:windowSplashScreenAnimatedIcon">@drawable/splash_icon_anim</item>
<item name="android:windowSplashScreenAnimationDuration">900</item>
```

Mỗi lần chạy `flutter_native_splash:create`, package **ghi đè** styles-v31 và đặt lại
`windowSplashScreenAnimatedIcon` về icon tĩnh `@drawable/android12splash`.
→ Sau mỗi lần gen, **phải chèn lại 2 dòng trên** (thay `android12splash` bằng
`splash_icon_anim` và thêm dòng duration) ở cả `values-v31` lẫn `values-night-v31`.

### File icon động

- `android/app/src/main/res/drawable/splash_icon_anim.xml` — **AnimationDrawable**
  (`<animation-list oneshot="true">`) dựng từ chính logo: zoom-in + fade overshoot,
  16 frame × 45ms (frame cuối dwell 200ms), dừng ở logo đầy đủ.
- Frames: `android/app/src/main/res/drawable-nodpi/splash_logo_00..15.webp`, sinh từ
  `assets/images/ic_launcher_960.png` bằng PIL (crop sát nội dung -> scale 0.62→1.0
  easeOutCubic + alpha easeOutCubic, canvas 640px trong suốt). Đặt trong `drawable-nodpi`
  để không bị scale theo density. Để chỉnh lại animation, re-render bằng script PIL
  rồi build lại.
  > 💡 Frame lưu dạng **WebP (quality 90)** để giảm size (~1.2MB PNG → ~220KB, -81%).
  > Android resolve `@drawable/splash_logo_NN` theo tên nên không cần sửa
  > `splash_icon_anim.xml`. Nếu re-render bằng PIL, nhớ `save(..., "WEBP", quality=90)`
  > thay vì PNG để khỏi phình lại.
  > ⚠️ VÙNG AN TOÀN (tránh "cut"): splash icon Android 12 chỉ hiện logo trong ~2/3
  > trung tâm. Logo lúc nghỉ (scale=1.0) phải bằng kích thước `android12splash.png`
  > tĩnh do package sinh — đo được **~40.4% rộng / ~46.5% cao** canvas. Vì vậy
  > `REST_MAX = 0.465` (fit cạnh lớn) và **KHÔNG overshoot** (zoom không vượt 100%),
  > nếu để logo to (vd 86%) hoặc overshoot >1.0 sẽ bị clip mép.
  > Lý do dùng frame animation, KHÔNG dùng AnimatedVectorDrawable: AVD chỉ animate được
  > vector path, không nhúng được ảnh raster (PNG) như logo thật.
- Hai loại file trên **không** bị `flutter_native_splash:create` xoá (package chỉ quản
  lý các file `splash_*` / `android12splash` của nó), nên sau mỗi lần gen chỉ cần
  re-apply phần `styles-v31` ở trên.

### Giữ splash để animation kịp chạy (BẮT BUỘC trên máy nhanh)

`windowSplashScreenAnimationDuration` chỉ là **thông tin** — hệ thống KHÔNG ép giữ
splash. Trên máy nhanh (vd S24 Ultra) cold-start chỉ chớp ~200–400ms rồi gỡ splash
ngay khi Flutter vẽ frame đầu → AVD chưa kịp chạy, người dùng thấy "không có icon".

Khắc phục bằng `androidx.core:core-splashscreen` + giữ splash đúng thời lượng animation:

- `android/app/build.gradle`: `implementation("androidx.core:core-splashscreen:1.0.1")`
- `MainActivity.onCreate` (trước `super.onCreate`):
  ```kotlin
  val splashScreen = installSplashScreen()
  val start = SystemClock.uptimeMillis()
  splashScreen.setKeepOnScreenCondition {
      SystemClock.uptimeMillis() - start < SPLASH_ANIM_DURATION_MS // 900L
  }
  ```
- `SPLASH_ANIM_DURATION_MS` (MainActivity) phải khớp `windowSplashScreenAnimationDuration` (styles-v31).

### Phạm vi hiển thị & cách test

- Hiệu ứng động chỉ chạy trên **Android 12+ (API 31+)**.
- Android < 12 và iOS dùng splash tĩnh (icon / background) như cấu hình.
- **Chỉ thấy animation khi COLD start** (kill hẳn app rồi mở lại / vừa cài). Warm/hot
  start không hiện splash.
