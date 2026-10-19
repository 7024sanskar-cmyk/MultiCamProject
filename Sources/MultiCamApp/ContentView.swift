import SwiftUI

struct CameraViewRepresentable: UIViewRepresentable {
    let previewView: PreviewView

    func makeUIView(context: Context) -> PreviewView { previewView }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var recorder = MultiCamRecorder()

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack(spacing: 3) {
                // TOP: Telephoto Lens
                ZStack(alignment: .topLeading) {
                    CameraViewRepresentable(previewView: recorder.telePreviewView)
                        .clipped()
                    Text("TELEPHOTO")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // MIDDLE: Main Wide Camera
                ZStack(alignment: .topLeading) {
                    CameraViewRepresentable(previewView: recorder.widePreviewView)
                        .clipped()
                    Text("MAIN CAMERA (1x)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // BOTTOM: Ultra-Wide Camera
                ZStack(alignment: .topLeading) {
                    CameraViewRepresentable(previewView: recorder.ultraWidePreviewView)
                        .clipped()
                    Text("ULTRA WIDE (0.5x)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Status & Record Button Overlay
            VStack {
                if !recorder.statusMessage.isEmpty {
                    Text(recorder.statusMessage)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                        .padding(.top, 44)
                }

                Spacer()

                Button(action: {
                    recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
                }) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 72, height: 72)

                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red)
                                .frame(width: 30, height: 30)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 58, height: 58)
                        }
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            recorder.startCameraSetup()
        }
    }
}