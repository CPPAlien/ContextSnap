import AppKit
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

    func updateImage(for id: Shot.ID, image: NSImage, isEdited: Bool = true) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].image = image
        shots[index].isEdited = isEdited
        if let data = Self.pngData(from: image) {
            try? data.write(to: shots[index].url, options: .atomic)
        }
    }

    func resetImage(for id: Shot.ID) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        updateImage(for: id, image: shots[index].originalImage, isEdited: false)
    }

    func clear() {
        shots.removeAll()
        selectedID = nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
