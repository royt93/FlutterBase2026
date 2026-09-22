pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    // 2.3.0+ required: google_mobile_ads 9.0.0's native play-services-ads
    // 25.3.0 dependency ships Kotlin metadata compiled with 2.3.0 — an
    // older plugin version fails compileDebugKotlin with "Module was
    // compiled with an incompatible version of Kotlin".
    id("org.jetbrains.kotlin.android") version "2.3.0" apply false
}

include(":app")
