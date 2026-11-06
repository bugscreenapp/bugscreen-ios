import Foundation

/// Effective literal wording snapshotted with a reporter's runtime configuration.
struct ReporterCopy: Decodable {
    let title: String
    let descriptionLabel: String
    let descriptionPlaceholder: String
    let typeLabel: String
    let submitLabel: String
    let successTitle: String
    let successMessage: String

    init(
        title: String = "Report an issue", descriptionLabel: String = "What happened?",
        descriptionPlaceholder: String = "Describe the bug…", typeLabel: String = "Type",
        submitLabel: String = "Create ticket", successTitle: String = "Thanks!",
        successMessage: String = "Your report has been sent."
    ) {
        self.title = title
        self.descriptionLabel = descriptionLabel
        self.descriptionPlaceholder = descriptionPlaceholder
        self.typeLabel = typeLabel
        self.submitLabel = submitLabel
        self.successTitle = successTitle
        self.successMessage = successMessage
    }

    private enum CodingKeys: String, CodingKey {
        case title, descriptionLabel, descriptionPlaceholder, typeLabel, submitLabel, successTitle, successMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReporterCopy()
        func text(_ key: CodingKeys, _ fallback: String, _ limit: Int) throws -> String {
            guard container.contains(key) else { return fallback }
            let supplied = try container.decode(String.self, forKey: key)
            let normalized = supplied.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let containsControlCharacters = supplied.unicodeScalars.contains {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
            }
            guard !normalized.isEmpty, normalized.unicodeScalars.count <= limit, !containsControlCharacters
            else { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid reporter wording") }
            return normalized
        }
        self.init(
            title: try text(.title, defaults.title, 60),
            descriptionLabel: try text(.descriptionLabel, defaults.descriptionLabel, 60),
            descriptionPlaceholder: try text(.descriptionPlaceholder, defaults.descriptionPlaceholder, 160),
            typeLabel: try text(.typeLabel, defaults.typeLabel, 60),
            submitLabel: try text(.submitLabel, defaults.submitLabel, 60),
            successTitle: try text(.successTitle, defaults.successTitle, 60),
            successMessage: try text(.successMessage, defaults.successMessage, 160)
        )
    }

    static func fromValues(_ values: [String: String]) throws -> ReporterCopy {
        try JSONDecoder().decode(ReporterCopy.self, from: JSONSerialization.data(withJSONObject: values))
    }

    var values: [String: String] {
        ["title": title, "descriptionLabel": descriptionLabel, "descriptionPlaceholder": descriptionPlaceholder,
         "typeLabel": typeLabel, "submitLabel": submitLabel, "successTitle": successTitle, "successMessage": successMessage]
    }
}
