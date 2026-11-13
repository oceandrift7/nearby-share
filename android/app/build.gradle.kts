plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "org.nearbyshare.prototype"
    compileSdk = 34
    defaultConfig {
        applicationId = "org.nearbyshare.prototype"
        minSdk = 29
        targetSdk = 34
        versionCode = 6
        versionName = "0.1.5-prototype"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    sourceSets.getByName("main").assets.srcDir("../../third-party")
}
dependencies {
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    implementation("com.google.zxing:core:3.5.3")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
