import javax.inject.Inject
import org.gradle.process.ExecOperations

plugins {
    alias(libs.plugins.android.library)
}

// ---------------------------------------------------------------------------
// Protobuf codegen.
//
// The schema source of truth is ../../proto (the repo root), shared with the Go
// relay and the iOS client. Generated code is NEVER checked in and NEVER
// hand-edited: a field number may only change by changing the .proto.
//
// protoc is resolved from Maven rather than the PATH — this Mac has no Homebrew
// and no system protoc (see root CLAUDE.md "Dev environment quirks").
// ---------------------------------------------------------------------------

val protocTool: Configuration = configurations.create("protocTool") {
    isCanBeConsumed = false
    isTransitive = false
}

/** Maven classifier for the protoc binary matching the machine running the build. */
val protocClassifier: String = run {
    val os = System.getProperty("os.name").lowercase()
    val arch = System.getProperty("os.arch").lowercase()
    val osPart = when {
        os.contains("mac") || os.contains("darwin") -> "osx"
        os.contains("win") -> "windows"
        else -> "linux"
    }
    val archPart = when (arch) {
        "aarch64", "arm64" -> "aarch_64"
        else -> "x86_64"
    }
    "$osPart-$archPart"
}

@CacheableTask
abstract class GenerateProtos @Inject constructor(
    private val execOps: ExecOperations,
) : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val protoFiles: ConfigurableFileCollection

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val protocExecutable: ConfigurableFileCollection

    @get:Internal
    abstract val protoRoot: DirectoryProperty

    @get:OutputDirectory
    abstract val javaOutputDir: DirectoryProperty

    @get:OutputDirectory
    abstract val kotlinOutputDir: DirectoryProperty

    @TaskAction
    fun generate() {
        val javaOut = javaOutputDir.get().asFile
        val kotlinOut = kotlinOutputDir.get().asFile
        listOf(javaOut, kotlinOut).forEach {
            it.deleteRecursively()
            it.mkdirs()
        }
        val protoc = protocExecutable.singleFile
        protoc.setExecutable(true)
        execOps.exec {
            commandLine(
                buildList {
                    add(protoc.absolutePath)
                    add("--proto_path=${protoRoot.get().asFile.absolutePath}")
                    add("--java_out=lite:${javaOut.absolutePath}")
                    add("--kotlin_out=lite:${kotlinOut.absolutePath}")
                    addAll(protoFiles.files.map { it.absolutePath })
                }
            )
        }
    }
}

val repoProtoDir = rootProject.layout.projectDirectory.dir("../proto")

val generateProtos = tasks.register<GenerateProtos>("generateProtos") {
    description = "Generates Java/Kotlin sources from the repo-root proto schema."
    protoRoot.set(repoProtoDir)
    protoFiles.from(repoProtoDir.asFileTree.matching { include("*.proto") })
    protocExecutable.from(protocTool)
    javaOutputDir.set(layout.buildDirectory.dir("generated/protobuf/java"))
    kotlinOutputDir.set(layout.buildDirectory.dir("generated/protobuf/kotlin"))
}

android {
    namespace = "app.relaymsg.proto"
    compileSdk {
        version = release(37)
    }
    defaultConfig {
        minSdk = 26
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.java?.addGeneratedSourceDirectory(generateProtos, GenerateProtos::javaOutputDir)
        variant.sources.kotlin?.addGeneratedSourceDirectory(generateProtos, GenerateProtos::kotlinOutputDir)
    }
}

dependencies {
    protocTool("com.google.protobuf:protoc:${libs.versions.protobuf.get()}:$protocClassifier@exe")
    api(libs.protobuf.javalite)
    api(libs.protobuf.kotlin.lite)

    testImplementation(libs.junit)
    testImplementation(libs.gson)
}
