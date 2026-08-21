import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key lives outside this repo, in the private
// royt93/myKeyStore repo. `keystore.local.properties` (gitignored) points at
// where that repo is cloned on this machine; see
// keystore.local.properties.example. Missing pointer or missing
// keystore.properties inside it → falls back to debug signing below.
val keystoreLocalProperties = Properties()
val keystoreLocalPropertiesFile = rootProject.file("keystore.local.properties")
if (keystoreLocalPropertiesFile.exists()) {
    keystoreLocalPropertiesFile.inputStream().use { keystoreLocalProperties.load(it) }
}
val myKeyStoreDir = keystoreLocalProperties.getProperty("myKeyStoreDir")
val releaseKeystoreFile = if (myKeyStoreDir != null) {
    file("$myKeyStoreDir/com.roy.admobwrapper/keystore.jks")
} else null
val releaseKeystoreProperties = Properties()
val releaseKeystorePropertiesFile = if (myKeyStoreDir != null) {
    file("$myKeyStoreDir/com.roy.admobwrapper/keystore.properties")
} else null
val hasReleaseSigning = releaseKeystoreFile != null &&
    releaseKeystoreFile.exists() &&
    releaseKeystorePropertiesFile != null &&
    releaseKeystorePropertiesFile.exists()
if (hasReleaseSigning) {
    releaseKeystorePropertiesFile!!.inputStream().use { releaseKeystoreProperties.load(it) }
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseKeystoreFile
                storePassword = requireNotNull(releaseKeystoreProperties.getProperty("storePassword")) {
                    "keystore.properties missing storePassword"
                }
                keyAlias = requireNotNull(releaseKeystoreProperties.getProperty("keyAlias")) {
                    "keystore.properties missing keyAlias"
                }
                keyPassword = requireNotNull(releaseKeystoreProperties.getProperty("keyPassword")) {
                    "keystore.properties missing keyPassword"
                }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
