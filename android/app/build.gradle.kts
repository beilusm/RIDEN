plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ridenps.riden_power_supply"

    // Phase 4 SDK pin: usb_serial 0.5.2 是纯 Java driver，无 native build —
    // 不需要 NDK。显式 pin minSdk=21 (Android 5.0+，usb_serial 兼容下界) +
    // targetSdk=34 (Android 14，稳定且主流)。compileSdk 不硬 pin — 跟随
    // `flutter.compileSdkVersion`，以满足 jni / jni_flutter /
    // flutter_plugin_android_lifecycle 等传递依赖的最低 SDK 要求
    // (Flutter 3.44.6 默认 compileSdk=36 / buildTools=35.0.0)。
    // 详见 docs/PHASE_4_ANDROID.md §5 Step 5 / §8 风险登记。
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.ridenps.riden_power_supply"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
