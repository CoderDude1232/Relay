package app.relaymsg.crypto

import com.goterl.lazysodium.LazySodiumJava
import com.goterl.lazysodium.SodiumJava
import java.io.File
import java.nio.file.Files

/**
 * Loads libsodium for JVM unit tests.
 *
 * lazysodium-java bundles native libraries inside its jar and normally extracts
 * them itself, but its resource loader tries to enumerate the `.dylib` jar entry
 * as if it were a directory and fails ("Failed to list contents of ...jar!/mac_arm/libsodium.dylib")
 * under this toolchain's JDK. So the library is extracted here to a temp file and
 * handed to `SodiumJava(absolutePath)`, which skips their loader entirely.
 *
 * This affects tests only. The production Android build uses lazysodium-android,
 * whose natives are unpacked from the APK by the platform — a different path that
 * is exercised by the instrumented tests, not these.
 */
object TestSodium {

    val lazySodium: LazySodiumJava by lazy { LazySodiumJava(SodiumJava(extractLibrary())) }

    private fun extractLibrary(): String {
        val resource = resourcePath()
        val stream = checkNotNull(TestSodium::class.java.classLoader?.getResourceAsStream(resource)) {
            "libsodium not found on the test classpath at '$resource' — is lazysodium-java a testImplementation dependency?"
        }
        val suffix = resource.substringAfterLast('.')
        val target: File = Files.createTempFile("libsodium-relay-test", ".$suffix").toFile()
        target.deleteOnExit()
        stream.use { input -> target.outputStream().use(input::copyTo) }
        return target.absolutePath
    }

    /** The bundled path matching this machine, using lazysodium's own naming. */
    private fun resourcePath(): String {
        val os = System.getProperty("os.name").lowercase()
        val arch = System.getProperty("os.arch").lowercase()
        val isArm = arch == "aarch64" || arch == "arm64"
        return when {
            os.contains("mac") || os.contains("darwin") ->
                if (isArm) "mac_arm/libsodium.dylib" else "mac/libsodium.dylib"
            os.contains("win") -> "windows64/libsodium.dll"
            else -> if (isArm) "arm64/libsodium.so" else "linux64/libsodium.so"
        }
    }
}
