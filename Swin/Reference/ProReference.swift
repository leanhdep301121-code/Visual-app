import Foundation

/// A bundled professional swing reference: pose sequence + 8 event frames,
/// produced by `swing-analyze/scripts/extract_pro.py`.
struct ProReference: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let label: String
    let view: String
    let handedness: String
    let fps: Double
    let imageSize: [Int]
    let events: [Int]
    let eventNames: [String]
    let frames: [Frame]

    struct Frame: Codable, Sendable {
        let x: [Float]
        let y: [Float]
        let conf: [Float]
    }

    static func bundled(named: String) -> ProReference? {
        guard let url = Bundle.main.url(forResource: named, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ProReference.self, from: data)
        } catch {
            print("[ProReference] decode failed for \(named): \(error)")
            return nil
        }
    }

    /// Bundled mp4 sitting next to the JSON. Convention: `<id>.mp4` in Resources/.
    var bundledVideoURL: URL? {
        Bundle.main.url(forResource: id, withExtension: "mp4")
    }

    /// Per-frame silhouette PNG bbox metadata produced by
    /// `scripts/extract_pro_silhouettes.py`. Lets us position the cropped PNG
    /// in the same coord system as the rest of the pose data.
    var bundledSilhouettes: ProSilhouetteMeta? {
        guard let url = Bundle.main.url(forResource: "\(id)_silhouettes", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(ProSilhouetteMeta.self, from: data)
    }
}

/// `<id>_silhouettes.json` schema. Per-frame bbox of the cropped person PNG in
/// the resized frame's pixel coords.
struct ProSilhouetteMeta: Codable, Sendable {
    let frameCount: Int
    let frameSize: [Int]      // [W, H] of resized frames
    let bboxes: [[Int]]        // (x0, y0, x1, y1) per frame
}

