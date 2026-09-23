@main
struct QC35ControlBundle: WidgetBundle {
    var body: some Widget { QC35Control() }
}

struct QC35Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.vanja.qc35.control.open") {
            ControlWidgetButton(action: OpenQC35Intent()) {
                Label("QC35", systemImage: "headphones")
            }
        }
        .displayName("QC35")
        .description("Choose a device and manage headset settings.")
    }
}

import SwiftUI
import WidgetKit
import AppIntents
