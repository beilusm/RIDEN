#!/usr/bin/env bash
# Phase 4 — pub-cache patches for AGP 9 / Gradle 9 compatibility.
#
# Source by .github/workflows/release-android.yml AND android-build.yml.
# Local developers should also run this script after `flutter pub get`
# (or `pub get --force`) — file content patch idempotent.
#
# Patches applied:
#   1. usb_serial 0.5.2       android/build.gradle  — 删 jcenter() + AGP 4.1 classpath
#   2. flutter_libserialport 0.4.0  android/build.gradle  — 删 jcenter + AGP 4.1 +
#     CMake native build + sourceSets 全空 + JVM 17 + Kotlin jvmTarget 17
#   3. flutter_libserialport 0.4.0  android/src/main/kotlin/.../FlutterLibserialportPlugin.kt
#     — v2 embedding stub (删 v1 Registrar 引用 — AGP 9 / Flutter 3.44 已移除)
#   4. file_picker 8.3.7  android/build.gradle  — 删 AGP 7.4.2 classpath +
#     compileSdk 跟随 rootProject
#
# 详见 docs/ARCHITECTURE.md "构建 Release → Android APK"。

set -euo pipefail

PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
USB_SERIAL="$PUB_CACHE/hosted/pub.dev/usb_serial-0.5.2/android/build.gradle"
FLUTTER_LIBSERIALPORT_BG="$PUB_CACHE/hosted/pub.dev/flutter_libserialport-0.4.0/android/build.gradle"
FLUTTER_LIBSERIALPORT_KT="$PUB_CACHE/hosted/pub.dev/flutter_libserialport-0.4.0/android/src/main/kotlin/org/sigrok/flutter_libserialport/FlutterLibserialportPlugin.kt"
FILE_PICKER="$PUB_CACHE/hosted/pub.dev/file_picker-8.3.7/android/build.gradle"

if [[ ! -f "$USB_SERIAL" ]]; then
  echo "::error::usb_serial 0.5.2 not found at $USB_SERIAL — run 'flutter pub get' first"
  exit 1
fi
if [[ ! -f "$FLUTTER_LIBSERIALPORT_BG" ]]; then
  echo "::error::flutter_libserialport 0.4.0 not found at $FLUTTER_LIBSERIALPORT_BG — run 'flutter pub get' first"
  exit 1
fi
if [[ ! -f "$FILE_PICKER" ]]; then
  echo "::error::file_picker 8.3.7 not found at $FILE_PICKER — run 'flutter pub get' first"
  exit 1
fi

echo "=== Patch 1/4: usb_serial 0.5.2/android/build.gradle ==="
cat > "$USB_SERIAL" <<'PATCH_USB_SERIAL'
group 'dev.bessems.usbserial'
version '1.0'

buildscript {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url "https://jitpack.io" }
    }

    gradle.projectsEvaluated {
        tasks.withType(JavaCompile) {
            options.compilerArgs << "-Xlint:unchecked" << "-Xlint:deprecation"
        }
    }
}

apply plugin: 'com.android.library'

android {
    compileSdk 34
    namespace 'dev.bessems.usbserial'

    defaultConfig {
        minSdkVersion 16
        testInstrumentationRunner "android.support.test.runner.AndroidJUnitRunner"
    }
    lintOptions {
        disable 'InvalidPackage'
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }
}

dependencies {
    implementation 'com.github.felHR85:UsbSerial:6.1.0'
}
PATCH_USB_SERIAL

echo "=== Patch 2/4: flutter_libserialport 0.4.0/android/build.gradle ==="
cat > "$FLUTTER_LIBSERIALPORT_BG" <<'PATCH_FLS_BUILD'
group 'org.sigrok.flutter_libserialport'
version '1.0-SNAPSHOT'

buildscript {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

apply plugin: 'com.android.library'

android {
    namespace 'org.sigrok.flutter_libserialport'

    final def rootProjectCompileSdk = rootProject.ext.has("compileSdkVersion")
        ? rootProject.ext.get("compileSdkVersion")
        : 34
    compileSdk rootProjectCompileSdk

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk 21
    }
    lintOptions {
        disable 'InvalidPackage'
    }

    sourceSets {
        main {
            java.srcDirs = []
            kotlin.srcDirs = []
            res.srcDirs = []
            assets.srcDirs = []
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
}
PATCH_FLS_BUILD

echo "=== Patch 3/4: flutter_libserialport 0.4.0/android/.../FlutterLibserialportPlugin.kt ==="
mkdir -p "$(dirname "$FLUTTER_LIBSERIALPORT_KT")"
cat > "$FLUTTER_LIBSERIALPORT_KT" <<'PATCH_FLS_KT'
package org.sigrok.flutter_libserialport

import io.flutter.embedding.engine.plugins.FlutterPlugin

class FlutterLibserialportPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
PATCH_FLS_KT

echo "=== Patch 4/4: file_picker 8.3.7/android/build.gradle ==="
cat > "$FILE_PICKER" <<'PATCH_FILEPICKER'
group 'com.mr.flutter.plugin.filepicker'
version '1.0-SNAPSHOT'

buildscript {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

apply plugin: 'com.android.library'

android {
    final def rootProjectCompileSdk = rootProject.ext.has("compileSdkVersion")
        ? rootProject.ext.get("compileSdkVersion")
        : 36
    compileSdk rootProjectCompileSdk

    defaultConfig {
        minSdk 21
        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"
    }
    lintOptions {
        disable 'InvalidPackage'
    }

    dependencies {
        implementation 'androidx.core:core:1.0.2'
        implementation 'androidx.annotation:annotation:1.0.0'
        implementation "androidx.lifecycle:lifecycle-runtime:2.1.0"
    }

    if (project.android.hasProperty("namespace")) {
        namespace 'com.mr.flutter.plugin.filepicker'
    }
}
PATCH_FILEPICKER

echo "=== pub-cache patches applied ==="
ls -la "$USB_SERIAL" "$FLUTTER_LIBSERIALPORT_BG" "$FLUTTER_LIBSERIALPORT_KT" "$FILE_PICKER"
