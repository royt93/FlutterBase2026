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



- Copy class AdMobManager




