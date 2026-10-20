import SwiftUI

struct CameraViewRepresentable: UIViewRepresentable {
    let previewView: PreviewView
    func makeUIView(context: Context) -> PreviewView { previewView }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var recorder = MultiCamRecorder()
    @State private var showLensPicker = false

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            let activeCameras = Array(recorder.selectedCameras.prefix(3))
            VStack(spacing: 3) {
                if activeCameras.indices.contains(0) {
                    ZStack(alignment: .bottomLeading) {
                        CameraViewRepresentable(previewView: recorder.previewView1).clipped()
                        Text(activeCameras[0].rawValue.uppercased()).font(.caption2.bold()).foregroundColor(.white).padding(5).background(Color.black.opacity(0.6)).cornerRadius(4).padding(6)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if activeCameras.indices.contains(1) {
                    ZStack(alignment: .bottomLeading) {
                        CameraViewRepresentable(previewView: recorder.previewView2).clipped()
                        Text(activeCameras[1].rawValue.uppercased()).font(.caption2.bold()).foregroundColor(.white).padding(5).background(Color.black.opacity(0.6)).cornerRadius(4).padding(6)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if activeCameras.indices.contains(2) {
                    ZStack(alignment: .bottomLeading) {
                        CameraViewRepresentable(previewView: recorder.previewView3).clipped()
                        Text(activeCameras[2].rawValue.uppercased()).font(.caption2.bold()).foregroundColor(.white).padding(5).background(Color.black.opacity(0.6)).cornerRadius(4).padding(6)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Controls Overlay
            VStack {
                VStack(spacing: 8) {
                    HStack {
                        Button(action: { recorder.toggleTorch() }) {
                            HStack(spacing: 4) {
                                Image(systemName: recorder.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                                Text(recorder.isTorchOn ? "FLASH" : "NO FLASH").font(.caption2.bold())
                            }
                            .foregroundColor(recorder.isTorchOn ? .black : .white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(recorder.isTorchOn ? Color.yellow : Color.black.opacity(0.75))
                            .cornerRadius(8)
                        }

                        Spacer()

                        Button(action: { showLensPicker = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "camera.badge.ellipsis")
                                Text("SELECT LENSES (\(activeCameras.count))").font(.caption2.bold())
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.blue.opacity(0.85))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 14)

                    if !recorder.statusMessage.isEmpty {
                        Text(recorder.statusMessage)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(8)
                    }
                }
                .padding(.top, 46)

                Spacer()

                Button(action: {
                    recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
                }) {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(Color.red).frame(width: 58, height: 58)
                        }
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showLensPicker) {
            NavigationView {
                List {
                    Section(header: Text("Choose up to 3 Lenses to Stream/Record")) {
                        ForEach(AvailableCamera.allCases) { cam in
                            HStack {
                                Text(cam.rawValue)
                                Spacer()
                                if recorder.selectedCameras.contains(cam) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if recorder.selectedCameras.contains(cam) {
                                    if recorder.selectedCameras.count > 1 {
                                        recorder.selectedCameras.removeAll { $0 == cam }
                                    }
                                } else {
                                    if recorder.selectedCameras.count < 3 {
                                        recorder.selectedCameras.append(cam)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Custom Lens Picker")
                .navigationBarItems(trailing: Button("Done") { showLensPicker = false })
            }
        }
        .onAppear {
            recorder.startCameraSetup()
        }
    }
}