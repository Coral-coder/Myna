import Foundation
import Photos
import UIKit
import Vision

/// Photos you take during a conversation — the whiteboard, the slide, the
/// receipt — attached to its note, with their text read on-device by Vision so
/// the note can use it.
///
/// Works with limited library access. Only photos whose capture time falls
/// inside a conversation are looked at, and only copies already on the iPhone:
/// Myna never asks iCloud for an original.
@MainActor
final class PhotosContext: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }

    func requestAccess() async -> Bool {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return isAuthorized
    }

    /// Photos taken between `start` and `end` (with a minute of slack on each side).
    func photos(from start: Date, to end: Date, limit: Int = 12) -> [PHAsset] {
        guard isAuthorized else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@ AND mediaType == %d",
            start.addingTimeInterval(-60) as NSDate,
            end.addingTimeInterval(60) as NSDate,
            PHAssetMediaType.image.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Text recognized in up to `limit` of the photos, skipping ones with little to read.
    func recognizedText(in assets: [PHAsset], limit: Int = 3) async -> [String] {
        var texts: [String] = []
        for asset in assets {
            guard texts.count < limit else { break }
            guard let image = await Self.localImage(for: asset, side: 2048)?.cgImage else { continue }
            let text = await Task.detached(priority: .utility) { Self.readText(in: image) }.value
            if text.count >= 12 { texts.append(String(text.prefix(1500))) }
        }
        return texts
    }

    /// A thumbnail for the note view.
    static func thumbnail(for identifier: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        return await localImage(for: asset, side: side)
    }

    // MARK: - Helpers

    private static func localImage(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                // .highQualityFormat calls back exactly once.
                continuation.resume(returning: image)
            }
        }
    }

    private nonisolated static func readText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
