plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bizdala.letflow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bizdala.letflow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Pinned to 26 (architecture.md §2: Android API 26+) rather than the
        // Flutter template default — REQ-419.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // flutter_appauth's AndroidManifest.xml declares a redirect-handling
        // intent filter with a `${appAuthRedirectScheme}` placeholder; it
        // must resolve to the app's own custom scheme
        // (com.bizdala.letflow:/oauth2redirect, per REQ-418's Keycloak
        // client registration) or the manifest merge fails. No auth logic
        // is added here — this is app-identity wiring only (REQ-419);
        // REQ-421 implements the actual OIDC flow.
        manifestPlaceholders["appAuthRedirectScheme"] = "com.bizdala.letflow"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
