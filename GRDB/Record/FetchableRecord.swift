import Foundation

/// Types that adopt `FetchableRecord` can be initialized from a database Row.
///
///     let row = try Row.fetchOne(db, sql: "SELECT ...")!
///     let player = Player(row)
///
/// The protocol comes with built-in methods that allow to fetch cursors,
/// arrays, or single records:
///
///     try Player.fetchCursor(db, sql: "SELECT ...", arguments:...) // Cursor of Player
///     try Player.fetchAll(db, sql: "SELECT ...", arguments:...)    // [Player]
///     try Player.fetchOne(db, sql: "SELECT ...", arguments:...)    // Player?
///
///     let statement = try db.makeStatement(sql: "SELECT ...")
///     try Player.fetchCursor(statement, arguments:...) // Cursor of Player
///     try Player.fetchAll(statement, arguments:...)    // [Player]
///     try Player.fetchOne(statement, arguments:...)    // Player?
public protocol FetchableRecord {
    
    // MARK: - Row Decoding
    
    /// Creates a record from `row`.
    ///
    /// For performance reasons, the row argument may be reused during the
    /// iteration of a fetch query. If you want to keep the row for later use,
    /// make sure to store a copy: `self.row = row.copy()`.
    init(row: Row)
    
    // MARK: - Customizing the Format of Database Columns
    
    /// When the FetchableRecord type also adopts the standard Decodable
    /// protocol, you can use this dictionary to customize the decoding process
    /// from database rows.
    ///
    /// For example:
    ///
    ///     // A key that holds a decoder's name
    ///     let decoderName = CodingUserInfoKey(rawValue: "decoderName")!
    ///
    ///     // A FetchableRecord + Decodable record
    ///     struct Player: FetchableRecord, Decodable {
    ///         // Customize the decoder name when decoding a database row
    ///         static let databaseDecodingUserInfo: [CodingUserInfoKey: Any] = [decoderName: "Database"]
    ///
    ///         init(from decoder: Decoder) throws {
    ///             // Print the decoder name
    ///             print(decoder.userInfo[decoderName])
    ///             ...
    ///         }
    ///     }
    ///
    ///     // prints "Database"
    ///     let player = try Player.fetchOne(db, ...)
    ///
    ///     // prints "JSON"
    ///     let decoder = JSONDecoder()
    ///     decoder.userInfo = [decoderName: "JSON"]
    ///     let player = try decoder.decode(Player.self, from: ...)
    static var databaseDecodingUserInfo: [CodingUserInfoKey: Any] { get }
    
    /// When the FetchableRecord type also adopts the standard Decodable
    /// protocol, this method controls the decoding process of nested properties
    /// from JSON database columns.
    ///
    /// The default implementation returns a JSONDecoder with the
    /// following properties:
    ///
    /// - dataDecodingStrategy: .base64
    /// - dateDecodingStrategy: .millisecondsSince1970
    /// - nonConformingFloatDecodingStrategy: .throw
    ///
    /// You can override those defaults:
    ///
    ///     struct Achievement: Decodable {
    ///         var name: String
    ///         var date: Date
    ///     }
    ///
    ///     struct Player: Decodable, FetchableRecord {
    ///         // stored in a JSON column
    ///         var achievements: [Achievement]
    ///
    ///         static func databaseJSONDecoder(for column: String) -> JSONDecoder {
    ///             let decoder = JSONDecoder()
    ///             decoder.dateDecodingStrategy = .iso8601
    ///             return decoder
    ///         }
    ///     }
    static func databaseJSONDecoder(for column: String) -> JSONDecoder
    
    /// When the FetchableRecord type also adopts the standard Decodable
    /// protocol, this property controls the decoding of date properties.
    ///
    /// Default value is .deferredToDate
    ///
    /// For example:
    ///
    ///     struct Player: FetchableRecord, Decodable {
    ///         static let databaseDateDecodingStrategy: DatabaseDateDecodingStrategy = .timeIntervalSince1970
    ///
    ///         var name: String
    ///         var registrationDate: Date // decoded from epoch timestamp
    ///     }
    static var databaseDateDecodingStrategy: DatabaseDateDecodingStrategy { get }
}

extension FetchableRecord {
    public static var databaseDecodingUserInfo: [CodingUserInfoKey: Any] {
        [:]
    }
    
    /// Returns a JSONDecoder with the following properties:
    ///
    /// - dataDecodingStrategy: .base64
    /// - dateDecodingStrategy: .millisecondsSince1970
    /// - nonConformingFloatDecodingStrategy: .throw
    public static func databaseJSONDecoder(for column: String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .throw
        decoder.userInfo = databaseDecodingUserInfo
        return decoder
    }
    
    public static var databaseDateDecodingStrategy: DatabaseDateDecodingStrategy {
        .deferredToDate
    }
}

extension FetchableRecord {
    
    // MARK: Fetching From Prepared Statement
    
    /// A cursor over records fetched from a prepared statement.
    ///
    ///     let statement = try db.makeStatement(sql: "SELECT * FROM player")
    ///     let players = try Player.fetchCursor(statement) // Cursor of Player
    ///     while let player = try players.next() { // Player
    ///         ...
    ///     }
    ///
    /// If the database is modified during the cursor iteration, the remaining
    /// elements are undefined.
    ///
    /// The cursor must be iterated in a protected dispatch queue.
    ///
    /// - parameters:
    ///     - statement: The statement to run.
    ///     - arguments: Optional statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: A cursor over fetched records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchCursor(
        _ statement: Statement,
        arguments: StatementArguments? = nil,
        adapter: RowAdapter? = nil)
    throws -> RecordCursor<Self>
    {
        try RecordCursor(statement: statement, arguments: arguments, adapter: adapter)
    }
    
    /// Returns an array of records fetched from a prepared statement.
    ///
    ///     let statement = try db.makeStatement(sql: "SELECT * FROM player")
    ///     let players = try Player.fetchAll(statement) // [Player]
    ///
    /// - parameters:
    ///     - statement: The statement to run.
    ///     - arguments: Optional statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: An array of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchAll(
        _ statement: Statement,
        arguments: StatementArguments? = nil,
        adapter: RowAdapter? = nil)
    throws -> [Self]
    {
        try Array(fetchCursor(statement, arguments: arguments, adapter: adapter))
    }
    
    /// Returns a single record fetched from a prepared statement.
    ///
    ///     let statement = try db.makeStatement(sql: "SELECT * FROM player")
    ///     let player = try Player.fetchOne(statement) // Player?
    ///
    /// - parameters:
    ///     - statement: The statement to run.
    ///     - arguments: Optional statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: An optional record.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchOne(
        _ statement: Statement,
        arguments: StatementArguments? = nil,
        adapter: RowAdapter? = nil)
    throws -> Self?
    {
        try fetchCursor(statement, arguments: arguments, adapter: adapter).next()
    }
}

extension FetchableRecord where Self: Hashable {
    /// Returns a set of records fetched from a prepared statement.
    ///
    ///     let statement = try db.makeStatement(sql: "SELECT * FROM player")
    ///     let players = try Player.fetchSet(statement) // Set<Player>
    ///
    /// - parameters:
    ///     - statement: The statement to run.
    ///     - arguments: Optional statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: A set of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchSet(
        _ statement: Statement,
        arguments: StatementArguments? = nil,
        adapter: RowAdapter? = nil)
    throws -> Set<Self>
    {
        try Set(fetchCursor(statement, arguments: arguments, adapter: adapter))
    }
}

extension FetchableRecord {
    
    // MARK: Fetching From SQL
    
    /// Returns a cursor over records fetched from an SQL query.
    ///
    ///     let players = try Player.fetchCursor(db, sql: "SELECT * FROM player") // Cursor of Player
    ///     while let player = try players.next() { // Player
    ///         ...
    ///     }
    ///
    /// If the database is modified during the cursor iteration, the remaining
    /// elements are undefined.
    ///
    /// The cursor must be iterated in a protected dispatch queue.
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: An SQL query.
    ///     - arguments: Statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: A cursor over fetched records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchCursor(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: RowAdapter? = nil)
    throws -> RecordCursor<Self>
    {
        try fetchCursor(db, SQLRequest<Void>(sql: sql, arguments: arguments, adapter: adapter))
    }
    
    /// Returns an array of records fetched from an SQL query.
    ///
    ///     let players = try Player.fetchAll(db, sql: "SELECT * FROM player") // [Player]
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: An SQL query.
    ///     - arguments: Statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: An array of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchAll(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: RowAdapter? = nil)
    throws -> [Self]
    {
        try fetchAll(db, SQLRequest<Void>(sql: sql, arguments: arguments, adapter: adapter))
    }
    
    /// Returns a single record fetched from an SQL query.
    ///
    ///     let player = try Player.fetchOne(db, sql: "SELECT * FROM player") // Player?
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: An SQL query.
    ///     - arguments: Statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: An optional record.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchOne(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: RowAdapter? = nil)
    throws -> Self?
    {
        try fetchOne(db, SQLRequest<Void>(sql: sql, arguments: arguments, adapter: adapter))
    }
}

extension FetchableRecord where Self: Hashable {
    /// Returns a set of records fetched from an SQL query.
    ///
    ///     let players = try Player.fetchSet(db, sql: "SELECT * FROM player") // Set<Player>
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: An SQL query.
    ///     - arguments: Statement arguments.
    ///     - adapter: Optional RowAdapter
    /// - returns: A set of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchSet(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        adapter: RowAdapter? = nil)
    throws -> Set<Self>
    {
        try fetchSet(db, SQLRequest<Void>(sql: sql, arguments: arguments, adapter: adapter))
    }
}

extension FetchableRecord {
    
    // MARK: Fetching From FetchRequest
    
    /// Returns a cursor over records fetched from a fetch request.
    ///
    ///     let request = try Player.all()
    ///     let players = try Player.fetchCursor(db, request) // Cursor of Player
    ///     while let player = try players.next() { // Player
    ///         ...
    ///     }
    ///
    /// If the database is modified during the cursor iteration, the remaining
    /// elements are undefined.
    ///
    /// The cursor must be iterated in a protected dispatch queue.
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: a FetchRequest.
    /// - returns: A cursor over fetched records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchCursor<R: FetchRequest>(_ db: Database, _ request: R) throws -> RecordCursor<Self> {
        let request = try request.makePreparedRequest(db, forSingleResult: false)
        precondition(request.supplementaryFetch == nil, "Not implemented: fetchCursor with supplementary fetch")
        return try fetchCursor(request.statement, adapter: request.adapter)
    }
    
    /// Returns an array of records fetched from a fetch request.
    ///
    ///     let request = try Player.all()
    ///     let players = try Player.fetchAll(db, request) // [Player]
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: a FetchRequest.
    /// - returns: An array of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchAll<R: FetchRequest>(_ db: Database, _ request: R) throws -> [Self] {
        let request = try request.makePreparedRequest(db, forSingleResult: false)
        if let supplementaryFetch = request.supplementaryFetch {
            let rows = try Row.fetchAll(request.statement, adapter: request.adapter)
            try supplementaryFetch(db, rows)
            return rows.map(Self.init(row:))
        } else {
            return try fetchAll(request.statement, adapter: request.adapter)
        }
    }
    
    /// Returns a single record fetched from a fetch request.
    ///
    ///     let request = try Player.filter(key: 1)
    ///     let player = try Player.fetchOne(db, request) // Player?
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: a FetchRequest.
    /// - returns: An optional record.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchOne<R: FetchRequest>(_ db: Database, _ request: R) throws -> Self? {
        let request = try request.makePreparedRequest(db, forSingleResult: true)
        if let supplementaryFetch = request.supplementaryFetch {
            guard let row = try Row.fetchOne(request.statement, adapter: request.adapter) else {
                return nil
            }
            try supplementaryFetch(db, [row])
            return .init(row: row)
        } else {
            return try fetchOne(request.statement, adapter: request.adapter)
        }
    }
}

extension FetchableRecord where Self: Hashable {
    /// Returns a set of records fetched from a fetch request.
    ///
    ///     let request = try Player.all()
    ///     let players = try Player.fetchSet(db, request) // Set<Player>
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - sql: a FetchRequest.
    /// - returns: A set of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public static func fetchSet<R: FetchRequest>(_ db: Database, _ request: R) throws -> Set<Self> {
        let request = try request.makePreparedRequest(db, forSingleResult: false)
        if let supplementaryFetch = request.supplementaryFetch {
            let rows = try Row.fetchAll(request.statement, adapter: request.adapter)
            try supplementaryFetch(db, rows)
            return Set(rows.lazy.map(Self.init(row:)))
        } else {
            return try fetchSet(request.statement, adapter: request.adapter)
        }
    }
}


// MARK: - FetchRequest

extension FetchRequest where RowDecoder: FetchableRecord {
    
    // MARK: Fetching Records
    
    /// A cursor over fetched records.
    ///
    ///     let request: ... // Some FetchRequest that fetches Player
    ///     let players = try request.fetchCursor(db) // Cursor of Player
    ///     while let player = try players.next() {   // Player
    ///         ...
    ///     }
    ///
    /// If the database is modified during the cursor iteration, the remaining
    /// elements are undefined.
    ///
    /// The cursor must be iterated in a protected dispatch queue.
    ///
    /// - parameter db: A database connection.
    /// - returns: A cursor over fetched records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public func fetchCursor(_ db: Database) throws -> RecordCursor<RowDecoder> {
        try RowDecoder.fetchCursor(db, self)
    }
    
    /// An array of fetched records.
    ///
    ///     let request: ... // Some FetchRequest that fetches Player
    ///     let players = try request.fetchAll(db) // [Player]
    ///
    /// - parameter db: A database connection.
    /// - returns: An array of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public func fetchAll(_ db: Database) throws -> [RowDecoder] {
        try RowDecoder.fetchAll(db, self)
    }
    
    /// The first fetched record.
    ///
    ///     let request: ... // Some FetchRequest that fetches Player
    ///     let player = try request.fetchOne(db) // Player?
    ///
    /// - parameter db: A database connection.
    /// - returns: An optional record.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public func fetchOne(_ db: Database) throws -> RowDecoder? {
        try RowDecoder.fetchOne(db, self)
    }
}

extension FetchRequest where RowDecoder: FetchableRecord & Hashable {
    /// A set of fetched records.
    ///
    ///     let request: ... // Some FetchRequest that fetches Player
    ///     let players = try request.fetchSet(db) // Set<Player>
    ///
    /// - parameter db: A database connection.
    /// - returns: A set of records.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    public func fetchSet(_ db: Database) throws -> Set<RowDecoder> {
        try RowDecoder.fetchSet(db, self)
    }
}

// MARK: - RecordCursor

/// A cursor of records. For example:
///
///     struct Player : FetchableRecord { ... }
///     try dbQueue.read { db in
///         let players: RecordCursor<Player> = try Player.fetchCursor(db, sql: "SELECT * FROM player")
///     }
public final class RecordCursor<Record: FetchableRecord>: Cursor {
    @usableFromInline enum _State {
        case idle, busy, done, failed
    }
    
    @usableFromInline let _statement: Statement
    @usableFromInline let _row: Row // Reused for performance
    @usableFromInline let _sqliteStatement: SQLiteStatement
    @usableFromInline var _state = _State.idle
    
    init(statement: Statement, arguments: StatementArguments? = nil, adapter: RowAdapter? = nil) throws {
        _statement = statement
        _row = try Row(statement: statement).adapted(with: adapter, layout: statement)
        _sqliteStatement = statement.sqliteStatement
        
        // Assume cursor is created for immediate iteration: reset and set arguments
        statement.reset(withArguments: arguments)
    }
    
    deinit {
        if _state == .busy {
            try? _statement.database.statementDidExecute(_statement)
        }
        
        // Statement reset fails when sqlite3_step has previously failed.
        // Just ignore reset error.
        try? _statement.reset()
    }
    
    @inlinable
    public func next() throws -> Record? {
        switch _state {
        case .done:
            // make sure this instance never yields a value again, even if the
            // statement is reset by another cursor.
            return nil
        case .idle:
            guard try _statement.database.statementWillExecute(_statement) == nil else {
                throw DatabaseError(
                    resultCode: SQLITE_MISUSE,
                    message: "Can't run statement that requires a customized authorizer from a cursor",
                    sql: _statement.sql,
                    arguments: _statement.arguments)
            }
            _state = .busy
        default:
            break
        }
        
        switch sqlite3_step(_sqliteStatement) {
        case SQLITE_DONE:
            _state = .done
            try _statement.database.statementDidExecute(_statement)
            return nil
        case SQLITE_ROW:
            return Record(row: _row)
        case let code:
            _state = .failed
            try _statement.database.statementDidFail(_statement, withResultCode: code)
        }
    }
}

// MARK: - DatabaseDateDecodingStrategy

/// `DatabaseDateDecodingStrategy` specifies how `FetchableRecord` types that
/// also  adopt the standard `Decodable` protocol decode their
/// `Date` properties.
///
/// For example:
///
///     struct Player: FetchableRecord, Decodable {
///         static let databaseDateDecodingStrategy = DatabaseDateDecodingStrategy.timeIntervalSince1970
///
///         var name: String
///         var registrationDate: Date // decoded from epoch timestamp
///     }
public enum DatabaseDateDecodingStrategy {
    /// The strategy that uses formatting from the Date structure.
    ///
    /// It decodes numeric values as a number of seconds since Epoch
    /// (midnight UTC on January 1st, 1970).
    ///
    /// It decodes strings in the following formats, assuming UTC time zone.
    /// Missing components are assumed to be zero:
    ///
    /// - `YYYY-MM-DD`
    /// - `YYYY-MM-DD HH:MM`
    /// - `YYYY-MM-DD HH:MM:SS`
    /// - `YYYY-MM-DD HH:MM:SS.SSS`
    /// - `YYYY-MM-DDTHH:MM`
    /// - `YYYY-MM-DDTHH:MM:SS`
    /// - `YYYY-MM-DDTHH:MM:SS.SSS`
    case deferredToDate
    
    /// Decodes numeric values as a number of seconds between the date and
    /// midnight UTC on 1 January 2001
    case timeIntervalSinceReferenceDate
    
    /// Decodes numeric values as a number of seconds between the date and
    /// midnight UTC on 1 January 1970
    case timeIntervalSince1970
    
    /// Decodes numeric values as a number of milliseconds between the date and
    /// midnight UTC on 1 January 1970
    case millisecondsSince1970
    
    /// Decodes dates according to the ISO 8601 standards
    @available(macOS 10.12, watchOS 3.0, tvOS 10.0, *)
    case iso8601
    
    /// Decodes a String, according to the provided formatter
    case formatted(DateFormatter)
    
    /// Decodes according to the user-provided function.
    ///
    /// If the database value  does not contain a suitable value, the function
    /// must return nil (GRDB will interpret this nil result as a conversion
    /// error, and react accordingly).
    case custom((DatabaseValue) -> Date?)
}
