import Foundation
import SwiftAgentKitA2A

actor SubAgentPoolA2AManagerProvider {
    private var manager: A2AManager?

    func setManager(_ manager: A2AManager?) {
        self.manager = manager
    }

    func currentManager() -> A2AManager? {
        manager
    }
}
