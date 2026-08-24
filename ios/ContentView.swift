import AVFoundation
import SwiftUI

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 64, alignment: .leading).font(.caption)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).frame(width: 72, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraController()

    var body: some View {
        ZStack(alignment: .bottom) {
            PreviewView(session: cam.session).ignoresSafeArea()

            VStack(spacing: 10) {
                HStack {
                    Picker("Lens", selection: Binding(
                        get: { cam.lensIndex },
                        set: { cam.switchLens(to: $0) }
                    )) {
                        Text("0.5x").tag(0)
                        Text("1x").tag(1)
                        Text("3x").tag(2)
                    }
                    .pickerStyle(.segmented).frame(width: 180)

                    Spacer()

                    Button(cam.isStreaming ? "STOP" : "STREAM") {
                        cam.isStreaming ? cam.stopStream() : cam.startStream()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(cam.isStreaming ? .red : .green)

                    Button(cam.torchOn ? "🔆" : "🔅") {
                        cam.toggleTorch(!cam.torchOn)
                    }
                }

                if cam.isStreaming {
                    Text("TCP :9750 · clients \(cam.clientCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Toggle("Manual controls", isOn: Binding(
                    get: { cam.manualMode }, set: { cam.setManual($0) }
                ))

                if cam.manualMode {
                    SliderRow(label: "ISO", value: $cam.iso, range: 34...4480, format: "%.0f")
                    SliderRow(label: "Shutter", value: $cam.shutterMs, range: 1...33, format: "%.1f ms")
                    SliderRow(label: "WB Temp", value: $cam.wbTemp, range: 2500...8000, format: "%.0f K")
                    SliderRow(label: "Focus", value: $cam.focusPos, range: 0...1, format: "%.2f")
                }

                SliderRow(label: "Zoom", value: Binding(
                    get: { Double(cam.zoomFactor) }, set: { cam.setZoom(CGFloat($0)) }
                ), range: 1...12, format: "%.1fx")

                SliderRow(label: "Bitrate", value: $cam.bitrateMbps, range: 8...50, format: "%.0f Mb")

                Toggle("4K (30fps)", isOn: Binding(
                    get: { cam.use4K },
                    set: { cam.use4K = $0; cam.applyFormatChange() }
                ))
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .onAppear { cam.setup() }
    }
}
