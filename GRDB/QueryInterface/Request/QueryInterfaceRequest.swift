// QueryInterfaceRequest is the type of requests generated by TableRecord:
//
//     struct Player: TableRecord { ... }
//     let playerRequest = Player.all() // QueryInterfaceRequest<Player>
//
// It wraps an SQLQuery, and has an attached type.
//
// The attached type helps decoding raw database values:
//
//     try dbQueue.read { db in
//         try playerRequest.fetchAll(db) // [Player]
//     }
//
// The attached type also helps the compiler validate associated requests:
//
//     playerRequest.including(required: Player.team) // OK
//     fruitRequest.including(required: Player.team)  // Does not compile

/// QueryInterfaceRequest is a request that generates SQL for you.
///
/// For example:
///
///     try dbQueue.read { db in
///         let request = Player
///             .filter(Column("score") > 1000)
///             .order(Column("name"))
///         let players = try request.fetchAll(db) // [Player]
///     }
///
/// See https://github.com/groue/GRDB.swift#the-query-interface
public struct QueryInterfaceRequest<T> {
    var query: SQLQuery
}

extension QueryInterfaceRequest {
    init(relation: SQLRelation) {
        self.init(query: SQLQuery(relation: relation))
    }
}

extension QueryInterfaceRequest: FetchRequest {
    public typealias RowDecoder = T
    
    /// Returns a tuple that contains a prepared statement that is ready to be
    /// executed, and an eventual row adapter.
    ///
    /// - parameter db: A database connection.
    /// - parameter singleResult: A hint as to whether the query should be optimized for a single result.
    /// - returns: A prepared statement and an eventual row adapter.
    /// :nodoc:
    public func makePreparedRequest(_ db: Database, forSingleResult singleResult: Bool) throws -> PreparedRequest {
        var query = self.query
        
        // Optimize query by setting a limit of 1 when appropriate
        if singleResult && !query.expectsSingleResult {
            query.limit = SQLLimit(limit: 1, offset: query.limit?.offset)
        }
        
        let (statement, adapter) = try SQLQueryGenerator(query).prepare(db)
        let associations = query.relation.prefetchedAssociations
        if associations.isEmpty {
            return PreparedRequest(statement: statement, adapter: adapter)
        } else {
            // Eager loading of prefetched associations
            return PreparedRequest(
                statement: statement,
                adapter: adapter,
                supplementaryFetch: { rows in
                    try prefetch(db, associations: associations, in: rows)
            })
        }
    }
    
    /// Returns the number of rows fetched by the request.
    ///
    /// - parameter db: A database connection.
    /// :nodoc:
    public func fetchCount(_ db: Database) throws -> Int {
        try query.fetchCount(db)
    }
    
    /// Returns the database region that the request looks into.
    ///
    /// - parameter db: A database connection.
    /// :nodoc:
    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
        var region = try SQLQueryGenerator(query).makeSelectStatement(db).selectedRegion
        
        // Iterate all prefetched associations
        var fifo = query.relation.prefetchedAssociations
        while !fifo.isEmpty {
            let association = fifo.removeFirst()
            
            // Build the query for prefetched rows.
            // CAUTION: Keep this code in sync with prefetch(_:associations:in:)
            let pivotMappings = try association.pivot.condition.columnMappings(db)
            let pivotColumns = pivotMappings.map(\.right)
            let pivotAlias = TableAlias()
            let prefetchedRelation = association
                .map(\.pivot.relation, { $0.qualified(with: pivotAlias) })
                .destinationRelation(fromOriginRows: { _ in [] /* no origin row */ })
                .annotated(with: pivotColumns.map { pivotAlias[Column($0)].forKey("grdb_\($0)") })
            let prefetchedQuery = SQLQuery(relation: prefetchedRelation)
            
            // Union region
            try region.formUnion(SQLQueryGenerator(prefetchedQuery).makeSelectStatement(db).selectedRegion)
            
            // Append nested prefetched associations (support for
            // A.including(all: A.bs.including(all: B.cs))
            fifo.append(contentsOf: prefetchedRelation.prefetchedAssociations)
        }
        
        return region
    }
}

extension QueryInterfaceRequest: SelectionRequest {
    // MARK: Request Derivation
    
    /// Creates a request which selects *selection*.
    ///
    ///     // SELECT id, email FROM player
    ///     var request = Player.all()
    ///     request = request.select([Column("id"), Column("email")])
    ///
    /// Any previous selection is replaced:
    ///
    ///     // SELECT email FROM player
    ///     request
    ///         .select([Column("id")])
    ///         .select([Column("email")])
    public func select(_ selection: [SQLSelectable]) -> QueryInterfaceRequest {
        map(\.query, { $0.select(selection) })
    }
    
    /// Creates a request which selects *selection*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT max(score) FROM player
    ///         let request = Player.all().select([max(Column("score"))], as: Int.self)
    ///         let maxScore: Int? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(_ selection: [SQLSelectable], as type: RowDecoder.Type = RowDecoder.self)
        -> QueryInterfaceRequest<RowDecoder>
    {
        return map(\.query, { $0.select(selection) }).asRequest(of: RowDecoder.self)
    }
    
    /// Creates a request which selects *selection*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT max(score) FROM player
    ///         let request = Player.all().select(max(Column("score")), as: Int.self)
    ///         let maxScore: Int? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(_ selection: SQLSelectable..., as type: RowDecoder.Type = RowDecoder.self)
        -> QueryInterfaceRequest<RowDecoder>
    {
        return select(selection, as: type)
    }
    
    /// Creates a request which selects *sql*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT max(score) FROM player
    ///         let request = Player.all().select(sql: "max(score)", as: Int.self)
    ///         let maxScore: Int? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        as type: RowDecoder.Type = RowDecoder.self)
        -> QueryInterfaceRequest<RowDecoder>
    {
        return select(literal: SQLLiteral(sql: sql, arguments: arguments), as: type)
    }
    
    /// Creates a request which selects an SQL *literal*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT IFNULL(name, 'Anonymous') FROM player WHERE id = 42
    ///         let request = Player.
    ///             .filter(primaryKey: 42)
    ///             .select(
    ///                 SQLLiteral(
    ///                     sql: "IFNULL(name, ?)",
    ///                     arguments: ["Anonymous"]),
    ///                 as: String.self)
    ///         let name: String? = try request.fetchOne(db)
    ///     }
    ///
    /// With Swift 5, you can safely embed raw values in your SQL queries,
    /// without any risk of syntax errors or SQL injection:
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT IFNULL(name, 'Anonymous') FROM player WHERE id = 42
    ///         let request = Player.
    ///             .filter(primaryKey: 42)
    ///             .select(
    ///                 literal: "IFNULL(name, \("Anonymous"))",
    ///                 as: String.self)
    ///         let name: String? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(
        literal sqlLiteral: SQLLiteral,
        as type: RowDecoder.Type = RowDecoder.self)
        -> QueryInterfaceRequest<RowDecoder>
    {
        return select(sqlLiteral.sqlSelectable, as: type)
    }
    
    /// Creates a request which appends *selection*.
    ///
    ///     // SELECT id, email, name FROM player
    ///     var request = Player.all()
    ///     request = request
    ///         .select([Column("id"), Column("email")])
    ///         .annotated(with: [Column("name")])
    public func annotated(with selection: [SQLSelectable]) -> QueryInterfaceRequest {
        map(\.query, { $0.annotated(with: selection) })
    }
}

extension QueryInterfaceRequest: FilteredRequest {
    // MARK: Request Derivation
    
    /// Creates a request with the provided *predicate promise* added to the
    /// eventual set of already applied predicates.
    ///
    ///     // SELECT * FROM player WHERE 1
    ///     var request = Player.all()
    ///     request = request.filter { db in true }
    public func filter(_ predicate: @escaping (Database) throws -> SQLExpressible) -> QueryInterfaceRequest {
        map(\.query, { $0.filter(predicate) })
    }
}

extension QueryInterfaceRequest: OrderedRequest {
    // MARK: Request Derivation
    
    /// Creates a request with the provided *orderings promise*.
    ///
    ///     // SELECT * FROM player ORDER BY name
    ///     var request = Player.all()
    ///     request = request.order { _ in [Column("name")] }
    ///
    /// Any previous ordering is replaced:
    ///
    ///     // SELECT * FROM player ORDER BY name
    ///     request
    ///         .order{ _ in [Column("email")] }
    ///         .reversed()
    ///         .order{ _ in [Column("name")] }
    public func order(_ orderings: @escaping (Database) throws -> [SQLOrderingTerm]) -> QueryInterfaceRequest {
        map(\.query, { $0.order(orderings) })
    }
    
    /// Creates a request that reverses applied orderings.
    ///
    ///     // SELECT * FROM player ORDER BY name DESC
    ///     var request = Player.all().order(Column("name"))
    ///     request = request.reversed()
    ///
    /// If no ordering was applied, the returned request is identical.
    ///
    ///     // SELECT * FROM player
    ///     var request = Player.all()
    ///     request = request.reversed()
    public func reversed() -> QueryInterfaceRequest {
        map(\.query, { $0.reversed() })
    }
    
    /// Creates a request without any ordering.
    ///
    ///     // SELECT * FROM player
    ///     var request = Player.all().order(Column("name"))
    ///     request = request.unordered()
    public func unordered() -> QueryInterfaceRequest {
        map(\.query, { $0.unordered() })
    }
}

extension QueryInterfaceRequest: AggregatingRequest {
    // MARK: Request Derivation
    
    /// Creates a request grouped according to *expressions promise*.
    public func group(_ expressions: @escaping (Database) throws -> [SQLExpressible]) -> QueryInterfaceRequest {
        map(\.query, { $0.group(expressions) })
    }
    
    /// Creates a request with the provided *predicate* added to the
    /// eventual set of already applied predicates.
    public func having(_ predicate: SQLExpressible) -> QueryInterfaceRequest {
        map(\.query, { $0.having(predicate) })
    }
}

extension QueryInterfaceRequest: _JoinableRequest {
    /// :nodoc:
    public func _including(all association: SQLAssociation) -> QueryInterfaceRequest {
        map(\.query, { $0._including(all: association) })
    }
    
    /// :nodoc:
    public func _including(optional association: SQLAssociation) -> QueryInterfaceRequest {
        map(\.query, { $0._including(optional: association) })
    }
    
    /// :nodoc:
    public func _including(required association: SQLAssociation) -> QueryInterfaceRequest {
        map(\.query, { $0._including(required: association) })
    }
    
    /// :nodoc:
    public func _joining(optional association: SQLAssociation) -> QueryInterfaceRequest {
        map(\.query, { $0._joining(optional: association) })
    }
    
    /// :nodoc:
    public func _joining(required association: SQLAssociation) -> QueryInterfaceRequest {
        map(\.query, { $0._joining(required: association) })
    }
}

extension QueryInterfaceRequest: JoinableRequest where T: TableRecord { }

extension QueryInterfaceRequest: KeyPathRefining {
    
    // MARK: Request Derivation
    
    /// Creates a request which returns distinct rows.
    ///
    ///     // SELECT DISTINCT * FROM player
    ///     var request = Player.all()
    ///     request = request.distinct()
    ///
    ///     // SELECT DISTINCT name FROM player
    ///     var request = Player.select(Column("name"))
    ///     request = request.distinct()
    public func distinct() -> QueryInterfaceRequest {
        map(\.query, { $0.distinct() })
    }
    
    /// Creates a request which expects a single result.
    ///
    /// It is unlikely you need to call this method. Its net effect is that
    /// QueryInterfaceRequest does not use any `LIMIT 1` sql clause when you
    /// call a `fetchOne` method.
    ///
    /// :nodoc:
    public func expectingSingleResult() -> QueryInterfaceRequest {
        map(\.query, { $0.expectingSingleResult() })
    }
    
    
    /// Creates a request which fetches *limit* rows, starting at *offset*.
    ///
    ///     // SELECT * FROM player LIMIT 1
    ///     var request = Player.all()
    ///     request = request.limit(1)
    ///
    /// Any previous limit is replaced.
    public func limit(_ limit: Int, offset: Int? = nil) -> QueryInterfaceRequest {
        map(\.query, { $0.limit(limit, offset: offset) })
    }
    
    /// Creates a request that allows you to define expressions that target
    /// a specific database table.
    ///
    /// In the example below, the "team.avgScore < player.score" condition in
    /// the ON clause could be not achieved without table aliases.
    ///
    ///     struct Player: TableRecord {
    ///         static let team = belongsTo(Team.self)
    ///     }
    ///
    ///     // SELECT player.*, team.*
    ///     // JOIN team ON ... AND team.avgScore < player.score
    ///     let playerAlias = TableAlias()
    ///     let request = Player
    ///         .all()
    ///         .aliased(playerAlias)
    ///         .including(required: Player.team.filter(Column("avgScore") < playerAlias[Column("score")])
    public func aliased(_ alias: TableAlias) -> QueryInterfaceRequest {
        map(\.query, { $0.qualified(with: alias) })
    }
    
    /// Creates a request bound to type Target.
    ///
    /// The returned request can fetch if the type Target is fetchable (Row,
    /// value, record).
    ///
    ///     // Int?
    ///     let maxScore = try Player
    ///         .select(max(scoreColumn))
    ///         .asRequest(of: Int.self)    // <--
    ///         .fetchOne(db)
    ///
    /// - parameter type: The fetched type Target
    /// - returns: A typed request bound to type Target.
    public func asRequest<RowDecoder>(of type: RowDecoder.Type) -> QueryInterfaceRequest<RowDecoder> {
        QueryInterfaceRequest<RowDecoder>(query: query)
    }
}

extension QueryInterfaceRequest {
    /// Turns a request into a SQLRelation.
    ///
    /// This method helps initializing associations:
    ///
    ///     struct Book: TableRecord {
    ///         // invokes Author.all().relation
    ///         static let author = belongsTo(Author.self)
    ///     }
    var relation: SQLRelation {
        let query = self.query
        
        // Prevent information loss
        GRDBPrecondition(!query.isDistinct, "Not implemented: join distinct queries")
        GRDBPrecondition(query.groupPromise == nil, "Can't join aggregated queries")
        GRDBPrecondition(query.havingExpressions.isEmpty, "Can't join aggregated queries")
        GRDBPrecondition(query.limit == nil, "Can't join limited queries")
        
        return query.relation
    }
}

extension QueryInterfaceRequest: TableRequest {
    /// :nodoc:
    public var databaseTableName: String {
        switch query.relation.source {
        case .table(tableName: let tableName, alias: _):
            // Use case:
            //
            //      let request = Player.all()
            //      request.filter(key: ...)
            //      request.filter(keys: ...)
            //      request.orderByPrimaryKey()
            return tableName
        case .query:
            // The only current use case for SQLSource.query is the
            // "trivial count query" (see SQLQuery.countQuery):
            //
            //      // SELECT COUNT(*) FROM (SELECT * FROM player LIMIT 10)
            //      let request = Player.limit(10)
            //      let count = try request.fetchCount(db)
            //
            // This query is currently never wrapped in a QueryInterfaceRequest
            // So this fatal error can not currently happen.
            fatalError("Request is not based on a database table")
        }
    }
}

extension QueryInterfaceRequest: DerivableRequest where T: TableRecord { }

extension QueryInterfaceRequest where T: MutablePersistableRecord {
    
    // MARK: Batch Delete
    
    /// Deletes matching rows; returns the number of deleted rows.
    ///
    /// - parameter db: A database connection.
    /// - returns: The number of deleted rows
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    @discardableResult
    public func deleteAll(_ db: Database) throws -> Int {
        try SQLQueryGenerator(query).makeDeleteStatement(db).execute()
        return db.changesCount
    }
    
    // MARK: Batch Update
    
    /// Updates matching rows; returns the number of updated rows.
    ///
    /// For example:
    ///
    ///     try dbQueue.write { db in
    ///         // UPDATE player SET score = 0
    ///         try Player.all().updateAll(db, [Column("score").set(to: 0)])
    ///     }
    ///
    /// - parameter db: A database connection.
    /// - parameter conflictResolution: A policy for conflict resolution,
    ///   defaulting to the record's persistenceConflictPolicy.
    /// - parameter assignments: An array of column assignments.
    /// - returns: The number of updated rows.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    @discardableResult
    public func updateAll(
        _ db: Database,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignments: [ColumnAssignment]) throws -> Int
    {
        let conflictResolution = conflictResolution ?? RowDecoder.persistenceConflictPolicy.conflictResolutionForUpdate
        guard let updateStatement = try SQLQueryGenerator(query).makeUpdateStatement(
            db,
            conflictResolution: conflictResolution,
            assignments: assignments) else
        {
            // database not hit
            return 0
        }
        try updateStatement.execute()
        return db.changesCount
    }
    
    /// Updates matching rows; returns the number of updated rows.
    ///
    /// For example:
    ///
    ///     try dbQueue.write { db in
    ///         // UPDATE player SET score = 0
    ///         try Player.all().updateAll(db, Column("score").set(to: 0))
    ///     }
    ///
    /// - parameter db: A database connection.
    /// - parameter conflictResolution: A policy for conflict resolution,
    ///   defaulting to the record's persistenceConflictPolicy.
    /// - parameter assignment: A column assignment.
    /// - parameter otherAssignments: Eventual other column assignments.
    /// - returns: The number of updated rows.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    @discardableResult
    public func updateAll(
        _ db: Database,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignment: ColumnAssignment,
        _ otherAssignments: ColumnAssignment...)
        throws -> Int
    {
        return try updateAll(db, onConflict: conflictResolution, [assignment] + otherAssignments)
    }
}

// MARK: - Eager loading of hasMany associations

/// Append rows from prefetched associations into the argument rows.
private func prefetch(_ db: Database, associations: [SQLAssociation], in rows: [Row]) throws {
    guard let firstRow = rows.first else {
        // No rows -> no prefetch
        return
    }
    
    // CAUTION: Keep this code in sync with QueryInterfaceRequest.databaseRegion(_:)
    for association in associations {
        let pivotMappings = try association.pivot.condition.columnMappings(db)
        
        let prefetchedRows: [[DatabaseValue] : [Row]]
        do {
            // Annotate prefetched rows with pivot columns, so that we can
            // group them.
            //
            // Those pivot columns are necessary when we prefetch
            // indirect associations:
            //
            //      // SELECT country.*, passport.citizenId AS grdb_citizenId
            //      // --                ^ the necessary pivot column
            //      // FROM country
            //      // JOIN passport ON passport.countryCode = country.code
            //      //               AND passport.citizenId IN (1, 2, 3)
            //      Citizen.including(all: Citizen.countries)
            //
            // Those pivot columns are redundant when we prefetch direct
            // associations (maybe we'll remove this redundancy later):
            //
            //      // SELECT *, authorId AS grdb_authorId
            //      // --        ^ the redundant pivot column
            //      // FROM book
            //      // WHERE authorId IN (1, 2, 3)
            //      Author.including(all: Author.books)
            let pivotColumns = pivotMappings.map(\.right)
            let pivotAlias = TableAlias()
            let prefetchedRelation = association
                .map(\.pivot.relation, { $0.qualified(with: pivotAlias) })
                .destinationRelation(fromOriginRows: { _ in rows })
                .annotated(with: pivotColumns.map { pivotAlias[Column($0)].forKey("grdb_\($0)") })
            prefetchedRows = try QueryInterfaceRequest(relation: prefetchedRelation)
                .fetchAll(db)
                .grouped(byDatabaseValuesOnColumns: pivotColumns.map { "grdb_\($0)" })
            // TODO: can we remove those grdb_ columns now that grouping has been done?
        }
        
        let groupingIndexes = firstRow.indexes(ofColumns: pivotMappings.map(\.left))
        for row in rows {
            let groupingKey = groupingIndexes.map { row.impl.databaseValue(atUncheckedIndex: $0) }
            let prefetchedRows = prefetchedRows[groupingKey, default: []]
            row.prefetchedRows.setRows(prefetchedRows, forKeyPath: association.keyPath)
        }
    }
}

extension Array where Element == Row {
    /// - precondition: Columns all exist in all rows. All rows have the same
    ///   columnns, in the same order.
    fileprivate func grouped(byDatabaseValuesOnColumns columns: [String]) -> [[DatabaseValue]: [Row]] {
        guard let firstRow = first else {
            return [:]
        }
        let indexes = firstRow.indexes(ofColumns: columns)
        return Dictionary(grouping: self, by: { row in
            indexes.map { row.impl.databaseValue(atUncheckedIndex: $0) }
        })
    }
}

extension Row {
    /// - precondition: Columns all exist in the row.
    fileprivate func indexes(ofColumns columns: [String]) -> [Int] {
        columns.map { column -> Int in
            guard let index = index(ofColumn: column) else {
                fatalError("Column \(column) is not selected")
            }
            return index
        }
    }
}

// MARK: - ColumnAssignment

/// A ColumnAssignment can update rows in the database.
///
/// You create an assignment from a column and an assignment method or operator,
/// such as `set(to:)` or `+=`:
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = 0
///         let assignment = Column("score").set(to: 0)
///         try Player.updateAll(db, assignment)
///     }
public struct ColumnAssignment {
    var column: ColumnExpression
    var value: SQLExpressible?
    
    func sql(_ context: inout SQLGenerationContext) -> String {
        if let value = value {
            return column.expressionSQL(&context, wrappedInParenthesis: false) +
                " = " +
                value.sqlExpression.expressionSQL(&context, wrappedInParenthesis: false)
        } else {
            return column.expressionSQL(&context, wrappedInParenthesis: false) +
                " = NULL"
        }
    }
}

extension ColumnExpression {
    /// Creates an assignment to a value.
    ///
    ///     Column("valid").set(to: true)
    ///     Column("score").set(to: 0)
    ///     Column("score").set(to: nil)
    ///     Column("score").set(to: Column("score") + Column("bonus"))
    ///
    ///     try dbQueue.write { db in
    ///         // UPDATE player SET score = 0
    ///         try Player.updateAll(db, Column("score").set(to: 0))
    ///     }
    public func set(to value: SQLExpressible?) -> ColumnAssignment {
        ColumnAssignment(column: self, value: value)
    }
}

/// Creates an assignment that adds a value
///
///     Column("score") += 1
///     Column("score") += Column("bonus")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score + 1
///         try Player.updateAll(db, Column("score") += 1)
///     }
public func += (column: ColumnExpression, value: SQLExpressible) -> ColumnAssignment {
    column.set(to: column + value)
}

/// Creates an assignment that subtracts a value
///
///     Column("score") -= 1
///     Column("score") -= Column("bonus")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score - 1
///         try Player.updateAll(db, Column("score") -= 1)
///     }
public func -= (column: ColumnExpression, value: SQLExpressible) -> ColumnAssignment {
    column.set(to: column - value)
}

/// Creates an assignment that multiplies by a value
///
///     Column("score") *= 2
///     Column("score") *= Column("factor")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score * 2
///         try Player.updateAll(db, Column("score") *= 2)
///     }
public func *= (column: ColumnExpression, value: SQLExpressible) -> ColumnAssignment {
    column.set(to: column * value)
}

/// Creates an assignment that divides by a value
///
///     Column("score") /= 2
///     Column("score") /= Column("factor")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score / 2
///         try Player.updateAll(db, Column("score") /= 2)
///     }
public func /= (column: ColumnExpression, value: SQLExpressible) -> ColumnAssignment {
    column.set(to: column / value)
}