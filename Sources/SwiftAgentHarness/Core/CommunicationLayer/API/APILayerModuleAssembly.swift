enum APILayerModuleAssembly {
    static func restModules() -> [any APILayerRESTEndpointModule] {
        [
            APILayerCoreStatusPromptModule(),
            APILayerCoreModelsModule(),
            APILayerConversationsModule(),
            APILayerCapabilitiesModule(),
            APILayerTracesModule(),
            APILayerMessagesModule(),
            APILayerUploadModule(),
            APILayerExecApprovalsModule(),
        ]
    }
}
