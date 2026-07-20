import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// D4: assinatura de release real. `key.properties` é gitignorado (aponta pro
// keystore, fora do repo) — sem ele, o build cai de volta na chave debug em
// vez de falhar, pra não quebrar quem não tiver o keystore local.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
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

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Sem key.properties local (ex.: outra máquina/CI sem o
                // keystore): cai pra debug key em vez de falhar o build.
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FFmpegKitNext (AT-3, build LGPL próprio arm64-v8a) — AAR local, não um
    // artefato Maven: baixado por tool/android/fetch_native_libs.ps1 (F2,
    // revisão de 2026-07-16) com SHA-256 pinado no script, igual à
    // libslimt.so (P2). O AAR não entra no git (ver .gitignore).
    implementation(files("libs/ffmpeg-kit-next.aar"))
    // Dependência TRANSITIVA do FFmpegKitNext (upstream declara
    // `api 'com.arthenica:smart-exception-java:0.2.1'`) que uma dependência
    // de arquivo local NÃO resolve — o AAR compila sem ela (só é usada no
    // corpo do <clinit> de FFmpegKitConfig), mas em RUNTIME qualquer chamada
    // ao FFmpegKit crasha com NoClassDefFoundError. Achado do smoke test
    // on-device da D3.2 (moto g86, 2026-07-17): o AT-3 não pegou porque o
    // bench foi buildado no Gradle do upstream, que resolve o POM.
    implementation("com.arthenica:smart-exception-java:0.2.1")
}
