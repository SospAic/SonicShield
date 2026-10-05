# 应用级 R8/ProGuard 规则（release 必备）。
#
# ## 为什么必须有这个文件
#
# Flutter 的 Gradle 插件在 `FlutterPlugin.kt:218` 里**写死**了
# `releaseBuildType.isMinifyEnabled = true` —— 也就是说，只要是 release 包，
# R8 代码压缩/混淆**一定**会打开，与本工程 build.gradle 怎么写无关。
# R8 会重命名（甚至删除）"只靠反射按类名加载"的类，而下列库正是这种加载方式。
#
# ## 不写会怎样（已实测复现，v1.9.0-alpha+17）
#
# mobile_scanner 6.0.11 自带的规则是 `-keep class com.google.mlkit.* { *; }`。
# ProGuard 里**单个 `*` 不跨越包分隔符**，所以它只保住 `com.google.mlkit` 这一层，
# `com.google.mlkit.vision.barcode.**` 等**子包照旧被重命名/裁剪**。
# ML Kit 的组件发现（`<meta-data>` + Class.forName）据此加载实现类，类名一变即失效，
# 扫码时原生方法通道直接抛空指针：
#
#   E/MethodChannel#dev.steenbakker.mobile_scanner/scanner/method:
#     Failed to handle method call
#     java.lang.NullPointerException: Attempt to invoke virtual method
#     'java.lang.Class java.lang.Object.getClass()' on a null object reference
#
# 结果：相机永远起不来，扫码页只显示「相机启动失败（MIUI 常见：相机被其它应用占用）」
# —— 而 debug 包（不压缩）同一机型同一路径完全正常。这就是"相机无法调用"的根因。
#
# ⚠️ 注意与 mobile_scanner 自带规则的关系：本文件是**补充**，不是替代。
#    自带规则仍会生效（consumer 规则）；这里把口径从"单星号"收紧到"双星号（含子包）"。

# ML Kit 组件发现按类名反射加载 → 必须保留**整棵子树**（`**` = 含所有子包）且不改名。
-keep class com.google.mlkit.** { *; }

# ML Kit 的内部实现（vex/c++ JNI 桥、zz* 内部类）同样按名加载。
-keep class com.google.android.gms.internal.mlkit_** { *; }

# 条码解码底层库（barhopper）。
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class com.google.photos.** { *; }

# 枚举：ML Kit / 序列化会按 `valueOf(String)` 取常量，需保住成员。
-keepclassmembers class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# 保留注解等运行时属性（反射/序列化依赖）。
-keepattributes RuntimeVisibleAnnotations,
                RuntimeVisibleParameterAnnotations,
                RuntimeVisibleTypeAnnotations,
                AnnotationDefault,
                Signature,
                InnerClasses,
                EnclosingMethod