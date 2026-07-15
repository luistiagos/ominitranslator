plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // §13.1: namespace == applicationId, sem o sufixo _app do nome do pacote Dart.
    namespace = "com.luistiagos.omnitranslator"
    compileSdk = flutter.compileSdkVersion
    // §13.1: o build LGPL do FFmpegKitNext (AT-3) e as libs do sherpa exigem
    // NDK r27+ (alinhamento 16 KB por padrão, §16.1). Não usar o default do
    // Flutter, que pode ser r26.
    ndkVersion = "27.0.12077973"

    compileOptions {
        // §13.1: Java/Kotlin 17.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.luistiagos.omnitranslator"
        // §13.1: minSdk 28. targetSdk ≥ 35 (16 KB obrigatório na Play desde nov/2025).
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // §13.2: release só arm64-v8a. Não empacotar 4 cópias das libs
            // nativas (sherpa/ONNX/ffmpeg) num APK universal.
            abiFilters += listOf("arm64-v8a")
        }
    }

    // §16.1: 16 KB — libs nativas não comprimidas e sem legacy packaging, para
    // o alinhamento do ELF valer no APK instalado.
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            // Assina com a debug key por ora (a config de release real é da D4).
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
