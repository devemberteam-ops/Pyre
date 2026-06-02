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

    // Force every plugin's Android module to compile against SDK 36 so the
    // file_picker / flutter_plugin_android_lifecycle AAR-metadata mismatch
    // doesn't block the build. Listener is wired before evaluationDependsOn
    // so it fires the moment the Android plugin registers.
    plugins.withId("com.android.library") {
        (project.extensions.findByName("android") as? com.android.build.gradle.LibraryExtension)?.apply {
            compileSdk = 36
        }
    }
    plugins.withId("com.android.application") {
        (project.extensions.findByName("android") as? com.android.build.gradle.AppExtension)?.apply {
            compileSdkVersion(36)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
