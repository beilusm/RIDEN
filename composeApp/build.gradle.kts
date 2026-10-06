import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import groovy.json.JsonSlurper

plugins {
    kotlin("multiplatform")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
    id("com.android.application")
}

val releaseVersion = rootProject.file("VERSION").readText().trim()
val versionParts = requireNotNull(Regex("([1-9][0-9]*)\\.([0-9]+)\\.([0-9]+)(?:-([1-9][0-9]*))?").matchEntire(releaseVersion)) {
    "VERSION must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-REVISION"
}.groupValues
val (major, minor, patch) = versionParts.drop(1).take(3).map(String::toInt)
val revision = versionParts[4].ifEmpty { "0" }.toInt()
require(major <= 99 && minor <= 99 && patch <= 655 && revision <= 99 && patch * 100 + revision <= 65535) {
    "Version exceeds Android or native installer limits"
}
// Native installers require numeric versions; reserve 100 revisions per release.
val nativeVersion = "$major.$minor.${patch * 100 + revision}"
version = releaseVersion

val localSigningFile = file(System.getProperty("user.home") + "/.android/riden-release-signing.json")
val localSigning = if (localSigningFile.isFile) JsonSlurper().parse(localSigningFile) as Map<*, *> else emptyMap<Any, Any>()
fun signingValue(environment: String, key: String) = providers.environmentVariable(environment).orNull
    ?: localSigning[key]?.toString()
val signingFile = signingValue("RIDEN_KEYSTORE_FILE", "storeFile")
val signingPassword = signingValue("RIDEN_KEYSTORE_PASSWORD", "storePassword")
val signingAlias = signingValue("RIDEN_KEY_ALIAS", "keyAlias")
val signingKeyPassword = signingValue("RIDEN_KEY_PASSWORD", "keyPassword")
val signingValues = listOf(signingFile, signingPassword, signingAlias, signingKeyPassword)
val hasReleaseSigning = signingValues.all { !it.isNullOrBlank() }
require(hasReleaseSigning || signingValues.all { it == null }) { "Release signing configuration is incomplete" }

kotlin {
    androidTarget()
    jvm("desktop")
    jvmToolchain(17)
    sourceSets {
        commonMain.dependencies {
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.materialIconsExtended)
            implementation(compose.components.resources)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.2")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
        }
        val desktopMain by getting {
            dependencies {
                implementation(compose.desktop.currentOs)
                implementation("com.fazecast:jSerialComm:2.11.0")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.10.2")
            }
        }
        androidMain.dependencies {
            implementation("androidx.activity:activity-compose:1.10.1")
            implementation("com.github.mik3y:usb-serial-for-android:3.9.0")
        }
        val desktopTest by getting {
            dependencies { implementation(compose.desktop.uiTestJUnit4) }
        }
    }
}

android {
    namespace = "io.github.beilusm.ridenps"
    compileSdk = 35
    defaultConfig {
        applicationId = "io.github.beilusm.ridenps"
        minSdk = 21
        targetSdk = 35
        versionCode = major * 10_000_000 + minor * 100_000 + patch * 100 + revision
        versionName = releaseVersion
    }
    if (hasReleaseSigning) {
        signingConfigs.create("ridenRelease") {
            storeFile = file(requireNotNull(signingFile))
            storePassword = signingPassword
            keyAlias = signingAlias
            keyPassword = signingKeyPassword
        }
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("ridenRelease")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

compose.desktop {
    application {
        mainClass = "io.github.beilusm.ridenps.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Deb, TargetFormat.Rpm, TargetFormat.Msi, TargetFormat.Dmg)
            packageName = "RIDEN"
            packageVersion = nativeVersion
            description = "RIDEN programmable power supply controller"
            vendor = "beilusm"
            linux {
                packageName = "riden"
                debPackageVersion = releaseVersion
                debMaintainer = "beilusm"
                iconFile.set(rootProject.file("linux/icons/hicolor/512x512/apps/io.github.beilusm.ridenps.png"))
            }
            windows {
                iconFile.set(rootProject.file("packaging/icons/riden.ico"))
                upgradeUuid = "8c8ded30-482b-4bd0-b542-2301674164f0"
                perUserInstall = true
                shortcut = true
                menu = true
                menuGroup = "RIDEN"
            }
            modules("java.sql", "jdk.unsupported")
        }
    }
}

val verifyReleaseSigning by tasks.registering {
    doLast { check(hasReleaseSigning) { "Configure RIDEN_KEYSTORE_* and RIDEN_KEY_* before building a release APK" } }
}
tasks.matching { it.name == "assembleRelease" }.configureEach { dependsOn(verifyReleaseSigning) }

tasks.withType<Test>().configureEach {
    if (providers.gradleProperty("skipUiTests").orNull == "true") exclude("**/AppUiTest.class")
    maxHeapSize = "512m"
}
