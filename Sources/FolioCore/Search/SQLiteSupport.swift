import Foundation
import Dispatch
import CSQLite

final class SQLiteStatement {
    private let database: OpaquePointer
    private var handle: OpaquePointer?
    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        let status = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard status == SQLITE_OK else { throw SearchIndexError.sqlite(status) }
    }
    deinit { sqlite3_finalize(handle) }
    func finish() { sqlite3_finalize(handle); handle = nil }
    func bind(_ text: String, _ index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = text.withCString { sqlite3_bind_text(handle, index, $0, Int32(text.utf8.count), transient) }
        guard status == SQLITE_OK else { throw SearchIndexError.sqlite(status) }
    }
    func bind(_ value: Int, _ index: Int32) throws {
        let status = sqlite3_bind_int64(handle, index, sqlite3_int64(value))
        guard status == SQLITE_OK else { throw SearchIndexError.sqlite(status) }
    }
    func bind(_ value: Double, _ index: Int32) throws {
        let status = sqlite3_bind_double(handle, index, value)
        guard status == SQLITE_OK else { throw SearchIndexError.sqlite(status) }
    }
    @discardableResult func step() throws -> Bool {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case SQLITE_INTERRUPT: throw SearchIndexError.cancelled
        default: throw SearchIndexError.sqlite(status)
        }
    }
    func text(_ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0 else { return "" }
        guard let bytes = sqlite3_column_text(handle, column),
              let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else { throw SearchIndexError.schemaMismatch }
        return text
    }
    func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
}

/// Owned by one search-index actor. Statements never leave that actor.
final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    init(file: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(file.path, &handle, flags, nil)
        guard result == SQLITE_OK, handle != nil else { sqlite3_close_v2(handle); handle = nil; throw SearchIndexError.sqlite(result) }
        sqlite3_busy_timeout(handle, 150)
        sqlite3_enable_load_extension(handle, 0)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 64 * 1024)
        sqlite3_limit(handle, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(handle, SQLITE_LIMIT_TRIGGER_DEPTH, 0)
    }
    deinit { close() }
    func close() { sqlite3_close_v2(handle); handle = nil }
    func statement(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SearchIndexError.closed }
        return try SQLiteStatement(database: handle, sql: sql)
    }
    func execute(_ sql: String) throws {
        guard let handle else { throw SearchIndexError.closed }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SearchIndexError.sqlite(result) }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

/// One synchronous SQLite operation owns the budget; no mutable state is shared
/// with UI threads. Cancellation/deadline checks bound otherwise expensive SQL.
final class SearchWorkBudget {
    let deadline: UInt64
    var callbacks = 0
    let maximumCallbacks: Int
    init(milliseconds: Int, virtualMachineSteps: Int) {
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, milliseconds)) * 1_000_000
        maximumCallbacks = max(0, virtualMachineSteps / 1000)
    }
    func shouldStop() -> Bool {
        callbacks += 1
        return callbacks > maximumCallbacks || DispatchTime.now().uptimeNanoseconds >= deadline || Task<Never, Never>.isCancelled
    }
}
