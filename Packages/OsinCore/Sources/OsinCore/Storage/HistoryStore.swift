import Foundation
import SQLite3

/// One point of metrics history. Fractions are 0...1, rates in bytes per second.
public struct HistoryPoint: Sendable, Equatable {
    public let date: Date
    public let cpu: Double
    public let memoryUsed: Double
    public let pressure: MemoryPressure
    public let diskFree: Double
    public let networkReceive: Double
    public let networkSend: Double
    public let batteryCharge: Double?
    public let score: Int
    /// Disk throughput in bytes per second.
    public let diskRead: Double
    public let diskWrite: Double

    public init(
        date: Date,
        cpu: Double,
        memoryUsed: Double,
        pressure: MemoryPressure,
        diskFree: Double,
        networkReceive: Double,
        networkSend: Double,
        batteryCharge: Double?,
        score: Int,
        diskRead: Double = 0,
        diskWrite: Double = 0
    ) {
        self.date = date
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.pressure = pressure
        self.diskFree = diskFree
        self.networkReceive = networkReceive
        self.networkSend = networkSend
        self.batteryCharge = batteryCharge
        self.score = score
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }

    public init(snapshot: SystemSnapshot) {
        let memory = snapshot.memory
        self.init(
            date: snapshot.date,
            cpu: snapshot.cpu.total,
            memoryUsed: memory.physicalBytes == 0 ? 0 : Double(memory.usedBytes) / Double(memory.physicalBytes),
            pressure: memory.pressure,
            diskFree: 1 - snapshot.disk.usedFraction,
            networkReceive: snapshot.network.receiveBytesPerSecond,
            networkSend: snapshot.network.sendBytesPerSecond,
            batteryCharge: snapshot.battery?.chargeFraction,
            score: snapshot.health.score,
            diskRead: snapshot.disk.readBytesPerSecond,
            diskWrite: snapshot.disk.writeBytesPerSecond
        )
    }
}

public struct HistoryStoreError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String {
        "SQLite error \(code): \(message)"
    }
}

/// Seven days of metrics in SQLite, downsampled as it ages (PRD §6.1):
/// raw samples for the last hour, one row per minute for the last day, one row per 15 minutes after that.
public actor HistoryStore {
    public static let retention: TimeInterval = 7 * 86400

    private enum Resolution: Int32 {
        case raw = 0
        case minute = 1
        case quarterHour = 2
    }

    /// Owns the SQLite handle so it is closed when the store goes away. Only touched from the actor.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        deinit {
            sqlite3_close(handle)
        }
    }

    private let connection: Connection
    private var db: OpaquePointer {
        connection.handle
    }

    /// Opens (or creates) the store at `url`, creating parent folders as needed.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try Connection(Self.open(url.path))
        try Self.prepareSchema(connection.handle)
    }

    private init(path: String) throws {
        connection = try Connection(Self.open(path))
        try Self.prepareSchema(connection.handle)
    }

    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(path: ":memory:")
    }

    /// Default location: `~/Library/Application Support/Osin/history.sqlite`.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Osin", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    public func record(_ point: HistoryPoint) throws {
        let sql = """
        INSERT INTO samples (ts, res, cpu, mem, pressure, disk, rx, tx, battery, score, dr, dw)
        VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(point.date.timeIntervalSince1970))
            sqlite3_bind_double(statement, 2, point.cpu)
            sqlite3_bind_double(statement, 3, point.memoryUsed)
            sqlite3_bind_int(statement, 4, Int32(point.pressure.rawValue))
            sqlite3_bind_double(statement, 5, point.diskFree)
            sqlite3_bind_double(statement, 6, point.networkReceive)
            sqlite3_bind_double(statement, 7, point.networkSend)
            if let battery = point.batteryCharge {
                sqlite3_bind_double(statement, 8, battery)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            sqlite3_bind_int(statement, 9, Int32(point.score))
            sqlite3_bind_double(statement, 10, point.diskRead)
            sqlite3_bind_double(statement, 11, point.diskWrite)
            try step(statement)
        }
    }

    /// Points since `since`, averaged into buckets of `bucket` seconds.
    /// Pressure keeps the worst value in a bucket and score the lowest, so short problems stay visible.
    public func points(since: Date, bucket: Int) throws -> [HistoryPoint] {
        let size = Int64(max(1, bucket))
        let sql = """
        SELECT (ts / \(size)) * \(size) AS t, AVG(cpu), AVG(mem), MAX(pressure), AVG(disk),
               AVG(rx), AVG(tx), AVG(battery), MIN(score), AVG(dr), AVG(dw)
        FROM samples WHERE ts >= ? GROUP BY t ORDER BY t
        """
        var result: [HistoryPoint] = []
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970))
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(HistoryPoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    cpu: sqlite3_column_double(statement, 1),
                    memoryUsed: sqlite3_column_double(statement, 2),
                    pressure: MemoryPressure(rawValue: Int(sqlite3_column_int(statement, 3))) ?? .normal,
                    diskFree: sqlite3_column_double(statement, 4),
                    networkReceive: sqlite3_column_double(statement, 5),
                    networkSend: sqlite3_column_double(statement, 6),
                    batteryCharge: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7),
                    score: Int(sqlite3_column_int(statement, 8)),
                    diskRead: sqlite3_column_double(statement, 9),
                    diskWrite: sqlite3_column_double(statement, 10)
                ))
            }
        }
        return result
    }

    /// Downsamples aging data and drops anything past the retention window.
    public func compact(now: Date = Date()) throws {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        try execute("BEGIN")
        do {
            try merge(from: .raw, into: .minute, bucket: 60, olderThan: nowSeconds - 3600)
            try merge(from: .minute, into: .quarterHour, bucket: 900, olderThan: nowSeconds - 86400)
            try execute("DELETE FROM samples WHERE ts < \(nowSeconds - Int64(Self.retention))")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rowCount() throws -> Int {
        var count = 0
        try withStatement("SELECT COUNT(*) FROM samples") { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return count
    }

    // MARK: - Internals

    private func merge(from source: Resolution, into target: Resolution, bucket: Int64, olderThan cutoff: Int64) throws {
        let aligned = (cutoff / bucket) * bucket
        try execute("""
        INSERT INTO samples (ts, res, cpu, mem, pressure, disk, rx, tx, battery, score, dr, dw)
        SELECT (ts / \(bucket)) * \(bucket), \(target.rawValue),
               AVG(cpu), AVG(mem), MAX(pressure), AVG(disk), AVG(rx), AVG(tx), AVG(battery), MIN(score), AVG(dr), AVG(dw)
        FROM samples WHERE res = \(source.rawValue) AND ts < \(aligned) GROUP BY ts / \(bucket)
        """)
        try execute("DELETE FROM samples WHERE res = \(source.rawValue) AND ts < \(aligned)")
    }

    private static func open(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw HistoryStoreError(code: code, message: message)
        }
        return handle
    }

    private static func prepareSchema(_ db: OpaquePointer) throws {
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS samples (
            ts INTEGER NOT NULL, res INTEGER NOT NULL,
            cpu REAL NOT NULL, mem REAL NOT NULL, pressure INTEGER NOT NULL, disk REAL NOT NULL,
            rx REAL NOT NULL, tx REAL NOT NULL, battery REAL, score INTEGER NOT NULL,
            dr REAL NOT NULL DEFAULT 0, dw REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts);
        CREATE INDEX IF NOT EXISTS samples_res_ts ON samples (res, ts);
        """
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw HistoryStoreError(code: code, message: String(cString: sqlite3_errmsg(db)))
        }
        try migrate(db)
    }

    /// Adds columns introduced after the first release to existing databases.
    private static func migrate(_ db: OpaquePointer) throws {
        var columns: Set<String> = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(samples)", -1, &statement, nil) == SQLITE_OK, let statement {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: name))
                }
            }
            sqlite3_finalize(statement)
        }
        for column in ["dr", "dw"] where !columns.contains(column) {
            let code = sqlite3_exec(db, "ALTER TABLE samples ADD COLUMN \(column) REAL NOT NULL DEFAULT 0", nil, nil, nil)
            guard code == SQLITE_OK else {
                throw HistoryStoreError(code: code, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw error(code) }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw error(code) }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(code) }
    }

    private func error(_ code: Int32) -> HistoryStoreError {
        HistoryStoreError(code: code, message: String(cString: sqlite3_errmsg(db)))
    }
}
