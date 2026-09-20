import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaPicker: UIViewControllerRepresentable {
    var completion: (Result<(URL, String), Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .any(of: [.videos, .images])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<(URL, String), Error>) -> Void
        init(_ completion: @escaping (Result<(URL, String), Error>) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let video = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let type = video ? UTType.movie.identifier : UTType.image.identifier
            provider.loadFileRepresentation(forTypeIdentifier: type) { [completion] url, error in
                do {
                    guard let url = url else { throw error ?? RemoteError.message("تعذّر جلب الأصل من الصور. نزّله من iCloud أولاً.") }
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: target)
                    DispatchQueue.main.async { completion(.success((target, video ? "video" : "image"))) }
                } catch { DispatchQueue.main.async { completion(.failure(error)) } }
            }
        }
    }
}
