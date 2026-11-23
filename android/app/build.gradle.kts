import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
//    id("kotlin-android")
    id("com.google.devtools.ksp")
    // ThekotlinOptions Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.projectDir.parentFile.resolve("key.properties") // key.properties lives in the project root

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val localProperties = Properties()
val localPropertiesFile = project.rootProject.file("local.properties")

if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use {
        localProperties.load(it)
    }
}

android {

    namespace = "com.gammagamma.grana"
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion // "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
            moduleName.set("app")
        }
    }

    defaultConfig {
        applicationId = "com.gammagamma.grana"
        // ML Kit GenAI Prompt & Agent APIs require minSdk 26+
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystorePropertiesFile.parentFile.resolve(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    flavorDimensions += "distribution"
    
    productFlavors {
        create("standard") {
            dimension = "distribution"
            // Standard flavor includes all features (Firebase, on-device ML Kit OCR + Gemini Nano 4, etc.)
        }
        
        create("foss") {
            dimension = "distribution"
            // FOSS flavor excludes proprietary libraries like Firebase & ML Kit
            // Suitable for F-Droid and other FOSS app stores
        }
    }

    buildTypes {
        debug {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            applicationIdSuffix = ".debug"
            // Aug 2026 removed due to new AGP
            // resValue("string", "app_name", "Grana-D")
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Aug 2026 removed due to new AGP
            // resValue("string", "app_name", "Grana")
        }
    }
    
}

flutter {
    source = "../.."
}

dependencies {
    // Scoped strictly to standard flavor so FOSS builds stay 100% free of proprietary Google binaries
    "standardImplementation"("com.google.mlkit:text-recognition:16.0.1")
    "standardImplementation"("com.google.mlkit:text-recognition-chinese:16.0.1")
    "standardImplementation"("com.google.mlkit:text-recognition-korean:16.0.1")
    "standardImplementation"("com.google.mlkit:genai-prompt:1.0.0-beta5")
    "standardImplementation"("com.google.mlkit:genai-agent:1.0.0-alpha1")
    "standardImplementation"("com.google.mlkit:genai-schema:1.0.0-alpha2")
    "standardImplementation"("androidx.appfunctions:appfunctions:1.0.0-alpha13")
    "kspStandard"("com.google.mlkit:genai-schema-compiler:1.0.0-alpha2")
    "kspStandard"("androidx.appfunctions:appfunctions-compiler:1.0.0-alpha13")
}

// Apply Firebase plugins only if google-services.json exists in standard flavor
// FOSS builds don't have this file
val googleServicesFile = file("src/standard/google-services.json")
if (googleServicesFile.exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}
