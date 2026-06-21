//
//  Internal SQLite errors for auxiliary session stores (dedupe, etc.) — map at boundary via ``SessionCatalogErrorMapping``.
//

import Foundation
import SQLite3

enum SessionSQLiteStoreError: Error, Sendable {
    case openFailed(sqliteCode: Int32)
    case execFailed(sqliteCode: Int32)
    case prepareFailed(sqliteCode: Int32)
    case stepFailed(sqliteCode: Int32)
}
