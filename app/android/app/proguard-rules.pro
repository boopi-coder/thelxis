# Used only when release minification is enabled (it is off for v0.1, see
# build.gradle.kts). flutter_webrtc's own consumer rules already keep
# com.cloudwebrtc.webrtc.**, org.webrtc.** and org.jni_zero.**; they are
# repeated here so this file stays correct if that plugin changes.
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.** { *; }
-dontwarn org.jni_zero.JniZeroJni

# This app: services are referenced from the manifest, the channel handler and
# the accessibility service are called from native code paths and must keep
# their names for stack traces.
-keep class io.thelxis.app.** { *; }
