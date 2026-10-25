# shared_preferences_android 2.5.0 使用 jnigen（JNI 在运行时按类名/方法签名反射查找
# Kotlin 运行时类）。R8 重命名或移除这些类会导致 NoSuchMethodError /
# ClassNotFoundException（启动读取 SharedPreferences 即崩溃白屏），因此保留
# Kotlin 运行时与插件的 JNI 反射表面。
-keep class kotlin.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
