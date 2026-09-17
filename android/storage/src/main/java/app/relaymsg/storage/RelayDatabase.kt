package app.relaymsg.storage

import android.content.Context
import java.io.File
import net.zetetic.database.sqlcipher.SQLiteDatabase

/**
 * Thin wrapper over the SQLCipher-encrypted database — the counterpart of iOS's
 * `Database`. Deliberately small: it owns connection setup, the schema
 * migration and a few query helpers, and nothing else.
 *
 * The passphrase is the master key from [MasterKeyStore], which is itself
 * wrapped by an Android Keystore key. Nothing readable is ever written to disk.
 */
class RelayDatabase private constructor(private val db: SQLiteDatabase) {

    companion object {
        private const val DATABASE_FILE = "relay.db"

        init {
            // sqlcipher-android 4.x requires the native library to be loaded
            // before any SQLiteDatabase call.
            System.loadLibrary("sqlcipher")
        }

        /**
         * Opens (creating on first use) the encrypted database and applies the
         * schema. [passphrase] is the raw master key; the caller may zero it
         * afterwards, as SQLCipher copies it.
         */
        fun open(context: Context, passphrase: ByteArray): RelayDatabase {
            val file = File(context.filesDir, DATABASE_FILE)
            val database = SQLiteDatabase.openOrCreateDatabase(file, passphrase, null, null)
            return RelayDatabase(database).apply { migrate() }
        }

        /** Opens an in-memory database. Used by instrumented tests. */
        fun openInMemory(passphrase: ByteArray): RelayDatabase {
            val database = SQLiteDatabase.openOrCreateDatabase(":memory:", passphrase, null, null)
            return RelayDatabase(database).apply { migrate() }
        }
    }

    /** Executes a statement with positional `?` bindings. */
    fun run(sql: String, bindings: List<Any?> = emptyList()) {
        db.execSQL(sql, bindings.toTypedArray())
    }

    /** Runs a query and maps each row with [map]. */
    fun <T> query(
        sql: String,
        bindings: List<Any?> = emptyList(),
        map: (Row) -> T,
    ): List<T> {
        db.rawQuery(sql, bindings.map { it?.toString() }.toTypedArray()).use { cursor ->
            val out = ArrayList<T>(cursor.count)
            while (cursor.moveToNext()) out.add(map(Row(cursor)))
            return out
        }
    }

    /** Runs [body] in a transaction, rolling back if it throws. */
    fun <T> transaction(body: () -> T): T {
        db.beginTransaction()
        try {
            val result = body()
            db.setTransactionSuccessful()
            return result
        } finally {
            db.endTransaction()
        }
    }

    fun close() = db.close()

    /**
     * Applies the schema when the database is new.
     *
     * Android has no installed base, so version 1 creates iOS's final shape in
     * one step. Later versions append `if (version < n)` blocks here, exactly as
     * iOS does — never by editing version 1, which existing installs have already
     * run.
     */
    private fun migrate() {
        val version = query("PRAGMA user_version;") { it.int(0) }.firstOrNull() ?: 0
        if (version >= Schema.VERSION) return
        transaction {
            if (version < 1) {
                Schema.STATEMENTS.forEach { run(it) }
            }
            run("PRAGMA user_version = ${Schema.VERSION};")
        }
    }

    /** A single result row, addressed by column index. */
    class Row(private val cursor: android.database.Cursor) {
        fun isNull(index: Int): Boolean = cursor.isNull(index)
        fun int(index: Int): Int = cursor.getInt(index)
        fun long(index: Int): Long = cursor.getLong(index)
        fun longOrNull(index: Int): Long? = if (isNull(index)) null else cursor.getLong(index)
        fun string(index: Int): String = cursor.getString(index)
        fun stringOrNull(index: Int): String? = if (isNull(index)) null else cursor.getString(index)
        fun blob(index: Int): ByteArray = cursor.getBlob(index)
        fun blobOrNull(index: Int): ByteArray? = if (isNull(index)) null else cursor.getBlob(index)
        fun boolean(index: Int): Boolean = cursor.getInt(index) != 0
    }
}
