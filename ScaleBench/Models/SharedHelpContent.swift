import Foundation

struct SharedHelpContent: Codable, Equatable {
    var schemaVersion: Int
    var title: String
    var sections: [SharedHelpSection]

    static let bundled: SharedHelpContent = {
        guard let url = Bundle.main.url(forResource: "help-content", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let content = try? JSONDecoder().decode(SharedHelpContent.self, from: data)
        else {
            return fallback
        }
        return content
    }()

    static let fallback = SharedHelpContent(
        schemaVersion: 1,
        title: "ScaleBench Help",
        sections: [
            SharedHelpSection(
                title: "Quick start",
                items: [
                    SharedHelpItem(type: .step, number: "1", title: "Scan and connect", text: "Power on a supported Bluetooth scale, tap Scan, then select the scale."),
                    SharedHelpItem(type: .step, number: "2", title: "Choose a mode", text: "Use Shot / Pour for normal public comparisons."),
                    SharedHelpItem(type: .step, number: "3", title: "Record", text: "Tap Start Recording. A timer sheet stays open so capture state is obvious."),
                    SharedHelpItem(type: .step, number: "4", title: "Stop and inspect", text: "Tap Stop and View Results. ScaleBench saves the recording automatically; export JSON only when you want a file copy.")
                ]
            ),
            SharedHelpSection(
                title: "Delivery score",
                items: [
                    SharedHelpItem(type: .text, text: "Shot / Pour and Transport Stress show the score math directly: delivered packets, usable readings, then score."),
                    SharedHelpItem(type: .text, text: "Delivered packets compares received updates against the 20-per-second Shot / Pour target."),
                    SharedHelpItem(type: .text, text: "Usable readings counts how many received weight readings could be trusted for scoring."),
                    SharedHelpItem(type: .text, text: "Packet checks shows how many extra packet details the scale exposes for diagnosis.")
                ]
            ),
            SharedHelpSection(
                title: "Source & legal",
                items: [
                    SharedHelpItem(type: .text, text: "ScaleBench is open source. The repository includes the app code, shared schemas, test fixtures, scoring documentation, privacy policy, and MIT license."),
                    SharedHelpItem(type: .link, title: "GitHub repository", value: "https://github.com/danielfcurrie-alt/ScaleBench"),
                    SharedHelpItem(type: .link, title: "Privacy policy", value: "https://github.com/danielfcurrie-alt/ScaleBench/blob/main/PRIVACY.md"),
                    SharedHelpItem(type: .link, title: "MIT license", value: "https://github.com/danielfcurrie-alt/ScaleBench/blob/main/LICENSE")
                ]
            )
        ]
    )
}

struct SharedHelpSection: Codable, Equatable, Identifiable {
    var id: String { title }
    var title: String
    var items: [SharedHelpItem]
}

struct SharedHelpItem: Codable, Equatable, Identifiable {
    var id: String { [type.rawValue, number, title, text, value].compactMap(\.self).joined(separator: "|") }
    var type: SharedHelpItemType
    var number: String?
    var title: String?
    var text: String?
    var value: String?
}

enum SharedHelpItemType: String, Codable, Equatable {
    case text
    case step
    case row
    case bullet
    case link
}
