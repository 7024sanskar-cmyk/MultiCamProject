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

            // 3 Stacked Viewfinders: Top (Telephoto), Middle (Main), Bottom (Ultra-Wide)
            VStack(spacing: 3) {
                ZStack(alignment: .bottomLeading) {
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

                ZStack(alignment: .bottomLeading) {
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

                ZStack(alignment: .bottomLeading) {
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

            // Top & Bottom Controls Overlay
            VStack {
                // Top Bar: Status + Flash Button + Output Mode Selector
                VStack(spacing: 8) {
                    HStack {
                        // Flash / Torch Toggle Button
                        Button(action: {
                            recorder.toggleTorch()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: recorder.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                                Text(recorder.isTorchOn ? "FLASH ON" : "FLASH OFF")
                                    .font(.caption2.bold())
                            }
                            .foregroundColor(recorder.isTorchOn ? .black : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(recorder.isTorchOn ? Color.yellow : Color.black.opacity(0.75))
                            .cornerRadius(8)
                        }

                        Spacer()

                        // Output Mode Toggle (3 Separate Videos vs 1 Combined Viewfinder Video)
                        HStack(spacing: 0) {
                            ForEach(RecordingOutputMode.allCases, id: \.self) { mode in
                                Button(action: {
                                    if !recorder.isRecording {
                                        recorder.outputMode = mode
                                    }
                                }) {
                                    Text(mode.rawValue)
                                        .font(.caption2.bold())
                                        .foregroundColor(recorder.outputMode == mode ? .black : .white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(recorder.outputMode == mode ? Color.white : Color.clear)
                                        .cornerRadius(6)
                                }
                            }
                        }
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 14)

                    if !recorder.statusMessage.isEmpty {
                        Text(recorder.statusMessage)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(8)
                    }
                }
                .padding(.top, 46)

                Spacer()

                // Shutter Record Button
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