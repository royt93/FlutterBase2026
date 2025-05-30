**Cập nhật dependencies:**  

google_mobile_ads: ^6.0.0

gma_mediation_applovin:

**Thêm quyền Android**

android/app/src/main/AndroidManifest.xml

    <uses-permission android:name=“com.google.android.gms.permission.AD_ID” />  
    <uses-permission android:name=“android.permission.INTERNET” />  
    <uses-permission android:name=“android.permission.ACCESS_NETWORK_STATE” />
    
    <manifest>  
	    <application>  
		    <meta-data  
		    android:name=“com.google.android.gms.ads.APPLICATION_ID”  
		    android:value=“ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy”/>  
	    </application>  
    </manifest>

**Cấu hình iOS:**

<!-- ios/Runner/Info.plist -->

```
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy</string>    
<key>SKAdNetworkItems</key>    
<array>    
<dict>    
<key>SKAdNetworkIdentifier</key>    
<string>cstr6suwn9.skadnetwork</string>    
</dict>    
</array>  

```

**Copy class AdMobManager: ad_mob_manager.dart , tốt nhất cope cả folder admob**

**Chú ý update các value về app id trong manifest và các ad id trong ad_mob_manager.dart**

**Copy class AdScreen: ad_screen.dart**

**Trong main thêm đoạn initialize AdMobManager**

    void main() async {  
	    WidgetsFlutterBinding.ensureInitialized();  
	    await AdMobManager().initialize();  
	    runApp(const MyApp());  
    }

**Chú ý dùng showAppOpenAd() cho hợp lý, nên show 1 lần duy nhất ở Splash.**

- Sửa UI: Xoá mấy cái Avatar glow, thêm UI sau
- Chú ý StreamSubscription? _subscription; trong class splash_screen

```
const Text(  
  "Please note: this action may show ads",  
  style: TextStyle(  
  fontWeight: FontWeight.bold,  
    fontSize: 16,  
    color: Colors.white,  
    shadows: [  
  Shadow(  
  blurRadius: 5.0,  
        color: Colors.black,  
        offset: Offset(1.0, 1.0),  
      ),  
    ],  
  ),  
),  
Container(  
  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),  
  child: LinearProgressIndicator(  
  backgroundColor: Colors.white.withValues(alpha: 0.1),  
    color: Colors.white,  
    borderRadius: BorderRadius.circular(45),  
  ),  
),

```

**Check code show quảng cáo trong screenA và screenB**