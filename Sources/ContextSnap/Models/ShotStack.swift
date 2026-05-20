import SwiftUI

@MainActor
final class ShotStack: ObservableObject {
    @Published var shots: [Shot] = []
    @Published var selectedID: Shot.ID?

    func append(_ shot: Shot) {
        shots.append(shot)
        selectedID = shot.id
    }

    func remove(_ shot: Shot) {
        shots.removeAll { $0.id == shot.id }
        if selectedID == shot.id { selectedID = shots.last?.id }
    }

    func clear() {
        shots.removeAll()
        selectedID = nil
    }
}
