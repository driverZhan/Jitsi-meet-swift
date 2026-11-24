import PhotosUI
import SwiftUI
import UIKit

/// Photo-library picker for the virtual background.
///
/// `PHPickerViewController` runs out of process, so the host app needs no photo-library
/// usage description and the user is not asked for permission: only the picture they pick
/// is handed over.
struct BackgroundImagePicker: UIViewControllerRepresentable {
    /// The picked picture, or nil when the user cancelled.
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (UIImage?) -> Void

        init(onPick: @escaping (UIImage?) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self)
            else {
                onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                // The item provider decodes off the main thread; the background effect and
                // SwiftUI state both live there.
                DispatchQueue.main.async {
                    self.onPick(image as? UIImage)
                }
            }
        }
    }
}
