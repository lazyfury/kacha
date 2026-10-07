// QR / barcode decoding via the system Vision framework.
//
// Offline, on-device and third-party-free. `detectSync` is the synchronous core
// (Vision's `perform` is synchronous) so `--selfcheck` can exercise it with a
// generated QR; `detect` hops off the main thread for the editor.

import CoreGraphics
import Vision

/// One decoded code: the payload plus a human-readable symbology label.
struct ScannedCode: Equatable {
    let payload: String
    let symbology: String
}

enum BarcodeReader {
    /// Decode every code Vision finds, off the main thread.
    static func detect(in image: CGImage) async -> [ScannedCode] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: detectSync(in: image))
            }
        }
    }

    /// The synchronous core. Returns the codes in Vision's reading order.
    static func detectSync(in image: CGImage) -> [ScannedCode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return decode(request.results)
    }

    private static func decode(_ results: [VNObservation]?) -> [ScannedCode] {
        (results as? [VNBarcodeObservation] ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue else { return nil }
            return ScannedCode(payload: payload, symbology: name(observation.symbology))
        }
    }

    /// A friendly label for the symbology (falls back to "条码").
    private static func name(_ symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "QR"
        case .aztec: return "Aztec"
        case .pdf417: return "PDF417"
        case .dataMatrix: return "Data Matrix"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .code93: return "Code 93"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        case .itf14: return "ITF-14"
        default: return "条码"
        }
    }
}
