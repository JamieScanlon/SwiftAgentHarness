//
//  `SQLITE_TRANSIENT` is not always visible to Swift; use the equivalent destructor value.
//

import SQLite3

enum SQLite3Transient {
    static let destructor: sqlite3_destructor_type = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
