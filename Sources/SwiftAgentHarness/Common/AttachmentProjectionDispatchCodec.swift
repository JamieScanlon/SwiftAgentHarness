import EasyJSON
import Foundation

enum AttachmentProjectionDispatchCodec {
    static func hasMaterializedBlocks(in additionalParameters: JSON?) -> Bool {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let projection = root["contextEngineAttachmentProjection"],
              case .object(let projectionObject) = projection,
              let blocksJSON = projectionObject["materializedBlocks"],
              case .array(let blocks) = blocksJSON else {
            return false
        }
        return !blocks.isEmpty
    }

    static func extractDispositions(from additionalParameters: JSON?) -> [String: String] {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let projection = root["contextEngineAttachmentProjection"],
              case .object(let projectionObject) = projection,
              let decisionsJSON = projectionObject["decisions"],
              case .array(let decisions) = decisionsJSON else {
            return [:]
        }
        var output: [String: String] = [:]
        for decision in decisions {
            guard case .object(let object) = decision,
                  case .string(let name)? = object["attachmentName"],
                  case .string(let disposition)? = object["disposition"] else {
                continue
            }
            output[name] = disposition
        }
        return output
    }
}
