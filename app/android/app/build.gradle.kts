plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.yousay.pocketpad"
    compileSdk = flutter.compileSdkVersion
    // ndkVersion 未指定：ネイティブコード不使用のためNDK（約600MB）を要求させない（IPv6オンリー回線対策）

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.yousay.pocketpad"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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

    // flutter-gradle-pluginのforceNdkDownload（ダミーCMakeを設定しNDK約700MBを強制DLさせる）を打ち消す。
    // ネイティブコード不使用のためNDK不要（IPv6オンリー回線のギガ節約）。
    // 注意：NDKが無いとlibflutter.so（未strip・約160MB/ABI）がそのまま入りAPKが約500MBになる。
    // flutter upgradeでエンジンが再DLされたら app/tool/strip_engine.ps1 を一度実行してからビルドすること。
    externalNativeBuild {
        cmake {
            path = null
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
