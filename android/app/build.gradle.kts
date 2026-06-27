plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.ononobi.facemeet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ononobi.facemeet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = "facemeet-key"
            keyPassword = "Speeddemo@5"
            storeFile = file("/Users/simeonononobi/Downloads/facemeet-release.jks")
            storePassword = "Speeddemo@5"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

// Copy FaceMeet app icon from Flutter assets into Android drawable resources
tasks.register<Copy>("copyAppIcon") {
    from("../../assets/images/app_icon-1776652935052.png")
    into("src/main/res/drawable")
    rename { "app_icon.png" }
}

tasks.whenTaskAdded {
    if (name == "preBuild" || name == "generateDebugResources" || name == "generateReleaseResources") {
        dependsOn("copyAppIcon")
    }
    if (name == "mapReleaseSourceSetPaths" || name == "mapDebugSourceSetPaths") {
        mustRunAfter("copyAppIcon")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.multidex:multidex:2.0.1")
    implementation("com.google.android.material:material:1.13.0")
    implementation("androidx.concurrent:concurrent-futures:1.3.0")
    implementation("com.android.installreferrer:installreferrer:2.2")
}
