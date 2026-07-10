plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ad_sdk_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // Must match the package the AppLovin ad units are registered against
        // (re-uses the host app's applicationId + 4 MAX ad unit IDs).
        // ⚠️ Conflicts with the main app on the same device — uninstall via
        //   `adb uninstall com.roy.admobwrapper` before installing this demo.
        // Namespace stays at "com.example.ad_sdk_example" so existing
        // MainActivity.kt path under kotlin/com/example/... keeps working.
        // demo-only — change this when copying the example into a real app.
        applicationId = "com.roy.admobwrapper"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
