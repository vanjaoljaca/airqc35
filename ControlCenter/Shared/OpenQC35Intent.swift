struct OpenQC35Intent: AppIntent {
    static let title: LocalizedStringResource = "Open QC35"
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        try requireHost()
        #else
        await QC35Panel.shared.show()
        #endif
        return .result()
    }
    private func requireHost() throws { throw ControlOpenError.hostRequired }
}

enum ControlOpenError: Error { case hostRequired }

import AppIntents
