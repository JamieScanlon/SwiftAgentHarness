import Foundation

enum ModelInvocationTaskContext {
    @TaskLocal static var callID: UUID?
    @TaskLocal static var logicalRequestID: UUID?
}
