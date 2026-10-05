allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 统一所有子项目（含 Flutter 插件）的 JVM Target：Java 与 Kotlin 必须一致，
// 否则 AGP 9 的 JVM-Target 校验会拒绝老插件（如 flutter_timezone）的混合配置。
// 注意：必须注册在 evaluationDependsOn(":app") 之前，否则 afterEvaluate 时 :app 已评估。
subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            project.extensions.configure<com.android.build.gradle.BaseExtension>("android") {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
                // 统一子项目（含 Flutter 插件）的 compileSdk：AGP 的 AAR 元数据校验
                // （checkDebugAarMetadata / checkReleaseAarMetadata）要求「依赖方」的
                // compileSdk 不低于「被依赖方」声明的值。老插件自带低 compileSdk，
                // 而其依赖（如 flutter_plugin_android_lifecycle）要求 36，会让
                // `:file_picker:checkDebugAarMetadata` 判红。只升不降，避免误伤高版本插件。
                if ((compileSdkVersion?.toIntOrNull() ?: 0) < 36) {
                    compileSdkVersion(36)
                }
            }
        }
        project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
            .configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
