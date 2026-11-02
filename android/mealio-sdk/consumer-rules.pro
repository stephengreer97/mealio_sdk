# Mealio Cart SDK consumer rules. These are applied to the partner app's
# R8/ProGuard run automatically (consumerProguardFiles in the AAR).

# The JavaScript bridge. R8 must not rename or strip the method the page calls
# (window.__mealioNativeBridge.post).
-keep class co.mealio.sdk.MealioNativeBridge { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
# WebView looks the annotation up at runtime, so it must survive R8.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault

# The login sheet is started by class name from the manifest.
-keep class co.mealio.sdk.MealioLoginActivity { *; }

# BouncyCastle references JDK classes (javax.naming, LDAP, ...) that Android
# does not have. Only the Ed25519 verifier is used.
-dontwarn org.bouncycastle.**
