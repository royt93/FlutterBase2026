#!/usr/bin/env bash
# Đóng gói thư mục example thành standalone project dùng pub.dev package
# cho partner / junior dev kèm file hướng dẫn AD_PROMPT_FLUTTER.MD.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(git -C "$package_dir" rev-parse --show-toplevel 2>/dev/null || cd "$package_dir/../.." && pwd)"

output_dir="/tmp/ad_sdk_partner_bundle"
zip_file="${package_dir}/build/ad_sdk_partner_bundle.zip"

echo "=== Đóng gói SDK Partner Bundle ==="
echo "SDK package: $package_dir"
echo "Temp dir:    $output_dir"
echo "Zip file:    $zip_file"

rm -rf "$output_dir"
mkdir -p "$output_dir/example"
mkdir -p "$(dirname "$zip_file")"

echo "1. Sao chép example project..."
# Dùng rsync hoặc cp loại trừ file rác và integration_test nội bộ
rsync -av \
  --exclude="build" \
  --exclude=".dart_tool" \
  --exclude=".gradle" \
  --exclude=".idea" \
  --exclude=".DS_Store" \
  --exclude="*.iml" \
  --exclude="android/.gradle" \
  --exclude="android/local.properties" \
  --exclude="ios/.symlinks" \
  --exclude="ios/Pods" \
  --exclude="ios/Podfile.lock" \
  --exclude="integration_test" \
  --exclude="test" \
  "$package_dir/example/" "$output_dir/example/" >/dev/null

echo "2. Chuyển đổi pubspec.yaml sang phiên bản pub.dev (^3.5.0)..."
example_pubspec="$output_dir/example/pubspec.yaml"

# Thay thế dependency path: ../ bằng phiên bản pub.dev
python3 -c "
import re

path = '$example_pubspec'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Thay thế applovin_admob_sdk:\n    path: ../ bằng applovin_admob_sdk: ^3.5.0
pattern = r'applovin_admob_sdk:\s*\n\s*path:\s*\.\./'
replacement = 'applovin_admob_sdk: ^3.5.0'

if not re.search(pattern, content):
    print('WARNING: Không tìm thấy pattern path: ../ trong pubspec.yaml')
else:
    content = re.sub(pattern, replacement, content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print('Đã cập nhật pubspec.yaml sang applovin_admob_sdk: ^3.5.0')
"

echo "3. Sao chép tài liệu AD_PROMPT_FLUTTER.MD..."
cp "$package_dir/doc/AD_PROMPT_FLUTTER.MD" "$output_dir/AD_PROMPT_FLUTTER.MD"

echo "4. Tạo README_PARTNER.md hướng dẫn nhanh..."
cat << 'EOF' > "$output_dir/README_PARTNER.md"
# Bộ tài liệu & Source mẫu tích hợp applovin_admob_sdk (v3.5.0)

Chào bạn, đây là gói tài liệu và project mẫu để bạn tích hợp SDK quảng cáo AdMob/AppLovin vào ứng dụng Flutter.

## 1. Cấu trúc gói bàn giao
- `AD_PROMPT_FLUTTER.MD`: Bản tài liệu đặc tả và hướng dẫn chi tiết 12 bước tích hợp (hỗ trợ cả AI coding agent và kỹ sư trực tiếp làm theo).
- `example/`: Ứng dụng mẫu Flutter hoàn chỉnh chạy độc lập, đã kết nối với package `applovin_admob_sdk: ^3.5.0` trên pub.dev.

## 2. Hướng dẫn nhanh cho Junior Dev
1. **Chạy thử app mẫu trước:**
   ```bash
   cd example
   flutter pub get
   flutter run
   ```
   Trải nghiệm toàn bộ các loại quảng cáo (Banner, Interstitial, Rewarded, App Open, UMP Consent, VIP) hoạt động thực tế trên máy thật hoặc giả lập.

2. **Cách đối chiếu code từ `example/` sang app của bạn:**
   - **Khởi tạo & Splash:** Xem `example/lib/main.dart` (các hàm trong `_SplashScreenState`, `AdManager().setNavigatorKey`).
   - **Khai báo Android:** Xem `example/android/app/src/main/AndroidManifest.xml` và `example/android/app/build.gradle.kts`.
   - **Khai báo iOS:** Xem `example/ios/Runner/Info.plist` (có sẵn mảng `SKAdNetworkItems` và `GADApplicationIdentifier`).
   - **Native Ad Factory:** Copy file `example/android/app/src/main/kotlin/.../T228CustomNativeAdFactory.kt` và `example/ios/Runner/T228CustomNativeAdFactory.swift` nếu bạn dùng loại Native Ad.

3. **Thực hiện theo tài liệu:**
   Mở file `AD_PROMPT_FLUTTER.MD`, điền các ID quảng cáo của dự án bạn vào Phần 0, và thực hiện theo các bước từ 4.0 đến 4.7.
EOF

echo "5. Xác thực project độc lập bằng flutter pub get..."
(
  cd "$output_dir/example"
  flutter pub get
)

echo "6. Tạo file nén zip: $zip_file..."
rm -f "$zip_file"
(
  cd "/tmp"
  zip -rq "$zip_file" "ad_sdk_partner_bundle"
)
rm -rf "$output_dir"

echo ""
echo "=== THÀNH CÔNG ==="
echo "Đã tạo gói bàn giao tại:"
echo "File zip: $zip_file ($(du -sh "$zip_file" | cut -f1))"
echo "Bạn có thể gửi file zip này cho partner junior dev."
