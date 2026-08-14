import com.android.build.gradle.LibraryExtension

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

// Plugin subprojects pin Java 8/11/17 via compileOptions while Kotlin defaults
// to the running JDK, which fails the JVM-target consistency check. Align each
// subproject's Kotlin target with its Java target instead.
subprojects {
    afterEvaluate {
        val projectName = name
        val android = extensions.findByName("android")
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>()
            .configureEach {
                // Read inside the task closure: compileOptions is finalized
                // only after the module's own afterEvaluate pass.
                val target = when (android) {
                    is com.android.build.api.dsl.LibraryExtension ->
                        android.compileOptions.targetCompatibility
                    is com.android.build.api.dsl.ApplicationExtension ->
                        android.compileOptions.targetCompatibility
                    else -> null
                }
                val jvm = when (target) {
                    JavaVersion.VERSION_1_8 -> "1.8"
                    JavaVersion.VERSION_11 -> "11"
                    JavaVersion.VERSION_17 -> "17"
                    else -> null
                }
                if (jvm != null) {
                    compilerOptions.jvmTarget.set(
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(jvm),
                    )
                }
                // flutter_avif_android (2022-era plugin) trips the strict
                // interface-member redeclaration check of the current language
                // version; compile it under the previous language version.
                if (projectName == "flutter_avif_android") {
                    compilerOptions.freeCompilerArgs.addAll(
                        listOf("-language-version", "1.9", "-api-version", "1.9"),
                    )
                }
            }
        if (projectName == "flutter_avif_android") {
            val lib = extensions.findByName("android")
            if (lib is com.android.build.api.dsl.LibraryExtension) {
                // The plugin pins compileSdk 31 but its transitive androidx
                // dependencies require 34+; raise it to the app's level.
                lib.compileSdk = 34
            }
        }
        // AGP 9 legacy mode copies the Kotlin classes into the javac output
        // dir, so bundling zips them twice ("already contains entry"). Drop
        // javac-output files that are exact copies of the Kotlin output.
        tasks.configureEach {
            val javac = this
            if (javac is JavaCompile &&
                javac.name.startsWith("compile") &&
                javac.name.endsWith("JavaWithJavac")
            ) {
                val kotlin = tasks.findByName(
                    javac.name.replace("JavaWithJavac", "Kotlin"),
                ) as? org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile
                if (kotlin != null) {
                    javac.doLast {
                        val kOut = kotlin.destinationDirectory.get().asFile
                        val jOut = javac.destinationDirectory.get().asFile
                        if (jOut.isDirectory && kOut.isDirectory) {
                            jOut.walkTopDown().forEach { f ->
                                if (f.isFile) {
                                    val rel =
                                        jOut.toPath().relativize(f.toPath()).toString()
                                    if (kOut.resolve(rel).exists()) {
                                        f.delete()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Strip GNU build IDs from the jni native library so reproducible-build
// verification against GitHub Actions builds succeeds.
subprojects {
    plugins.withId("com.android.library") {
        if (name == "jni") {
            extensions.configure<LibraryExtension>("android") {
                defaultConfig {
                    externalNativeBuild {
                        cmake {
                            arguments += "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=none"
                        }
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
