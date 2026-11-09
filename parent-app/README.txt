Quelltext der Android-App "Eltern Bildschirmzeit" (Kotlin, Jetpack Compose, minSdk 26).
Bauen: Android SDK 35 + JDK 17, local.properties mit sdk.dir=... anlegen, dann ./gradlew assembleDebug
Tests: ./gradlew testDebugUnitTest   (nutzen app/src/test/resources/relay_vectors.json = tests/vectors/relay_vectors.json)
Die fertige APK liegt separat: Eltern-Bildschirmzeit.apk
