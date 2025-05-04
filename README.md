- Cập nhật dependencies:
google_mobile_ads: ^6.0.0



- Thêm quyền Android
<!-- android/app/src/main/AndroidManifest.xml -->

<uses-permission android:name="com.google.android.gms.permission.AD_ID" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

<manifest>
  <application>
    <meta-data
      android:name="com.google.android.gms.ads.APPLICATION_ID"
      android:value="ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy"/>
  </application>
</manifest>



- Cấu hình iOS:
<!-- ios/Runner/Info.plist -->
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy</string>
<key>SKAdNetworkItems</key>
<array>
<dict>
<key>SKAdNetworkIdentifier</key>
<string>cstr6suwn9.skadnetwork</string>
</dict>
</array>



- Copy class AdMobManager: ad_mob_manager.dart


- Chú ý update các value về app id trong manifest và các ad id trong ad_mob_manager.dart


- Copy class AdScreen: ad_screen.dart


- Trong main thêm đoạn initialize AdMobManager
  void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AdMobManager().initialize();
  runApp(const MyApp());
  }

 
- Chú ý dùng showAppOpenAd() cho hợp lý, nên show 1 lần duy nhất ở Splash.
