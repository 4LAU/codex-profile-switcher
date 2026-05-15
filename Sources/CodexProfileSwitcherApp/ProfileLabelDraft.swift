import CodexProfileCore
import Foundation

struct ProfileLabelDraft {
    private(set) var profileId: String?
    var text: String = ""

    mutating func sync(selectedId: String?, profiles: [ProfileConfig]) {
        guard let selectedId,
              let profile = profiles.first(where: { $0.id == selectedId }) else {
            self.profileId = nil
            self.text = ""
            return
        }

        self.profileId = profile.id
        self.text = profile.label
    }

    func commitValue() -> (id: String, label: String)? {
        guard let profileId else { return nil }
        let trimmed = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (profileId, trimmed)
    }
}
