plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.sonicshield.sonic_shield"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 等插件要求 Java 8+ API 脱糖。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sonicshield.sonic_shield"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ⚠️ 这里**故意不写** `ndk { abiFilters += ... }`。
        // Flutter 的 Gradle 插件在本文件顶部的 `plugins{}` 里 apply 时就会执行
        // `extension.defaultConfig.ndk { abiFilters.clear(); abiFilters.addAll(PLATFORM_ABI_LIST) }`
        // （flutter_tools/gradle/.../FlutterPlugin.kt:591-600），而 `android{}` 在其后求值 ——
        // 所以在这里写 `+=` 只会**追加重复项**：既排除不掉 ABI、也减不了体积。
        // 实测 `unzip -l app-debug.apk | grep lib/` 三个 ABI 齐全。
        //
        // 这与"尽可能向下兼容低版本安卓"是**一致**的：`PLATFORM_ABI_LIST` 是
        // `[armeabi-v7a, arm64-v8a, x86_64]`（FlutterPluginConstants.kt:48-53），
        // **armeabi-v7a 必须保留** —— API 24/25 时代的低端机大量是 32 位，
        // 排除它会让这些设备 `INSTALL_FAILED_NO_MATCHING_ABIS` 直接装不上。
        // 若确实要减体积，用 `flutter build apk --split-per-abi`（按 ABI 拆成多份 APK），
        // **不要**在这里收窄 abiFilters。
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
