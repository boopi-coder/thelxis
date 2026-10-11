import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (never committed):
//   storeFile=/abs/path/to/upload.jks   storePassword=...   keyAlias=...   keyPassword=...
// Without it (local builds, forks, PR CI) release builds fall back to the debug key.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val releaseKeyConfigured =
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { !keystoreProperties.getProperty(it).isNullOrBlank() }

android {
    namespace = "io.thelxis.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // flutter_webrtc (libwebrtc AAR) needs Java 8+ APIs; the Flutter template's 17 satisfies it.
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.thelxis.app"
        // 24 = Android 7.0, the first release with AccessibilityService.dispatchGesture.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeyConfigured) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    packaging {
        jniLibs {
            // libwebrtc and other native plugins may each bundle libc++_shared.so.
            pickFirsts += "**/libc++_shared.so"
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeyConfigured) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // v0.1: R8 shrinking is OFF on purpose. The APK is dominated by
            // libwebrtc's native libraries, which R8 cannot shrink, so the size
            // win is small, while one missed keep rule (JNI-reflected classes in
            // org.webrtc / org.jni_zero) would only show up as a crash on a real
            // device. flutter_webrtc already ships consumer rules for those
            // packages and proguard-rules.pro keeps this app's classes, so
            // enabling minify later only needs isMinifyEnabled/isShrinkResources
            // set to true (and the default proguard-android-optimize.txt added).
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles("proguard-rules.pro")
        }
    }
}

dependencies {
    // FileProvider for handing downloaded update APKs to the package installer.
    // Declared explicitly instead of relying on a transitive copy.
    implementation("androidx.core:core:1.15.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
