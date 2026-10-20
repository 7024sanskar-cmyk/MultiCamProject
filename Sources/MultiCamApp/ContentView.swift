import SwiftUI

struct CameraViewRepresentable: UIViewRepresentable {
    let previewView: PreviewView
    func makeUIView(context: Context) -> PreviewView { previewView }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var recorder = MultiCamRecorder()
    @State private var showLensPicker = false
    @State private var show4KPicker = false
    @State private var tempSelectedCameras: [AvailableCamera] = [.telephoto, .mainWide]

    // Helper to label the screen position of a camera
    func positionBadge(for index: Int, total: Int) -> String {
        if total == 2 {
            return index == 0 ? "TOP" : "BOTTOM"
        } else {
            if index == 0 { return "TOP" }
            else if index == 1 { return "MIDDLE" }
            else { return "BOTTOM" }
        }
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            // Dynamic Stacked Viewfinders
            let activeCameras = Array(recorder.selectedCameras.prefix(3))
            VStack(spacing: 3) {
                if activeCameras.indices.contains(0) {
                    ZStack(alignment: .bottomLeading) {
                        CameraViewRepresentable(previewView: recorder.previewView1).clipped()
                        HStack {
                            Text("[\(positionBadge(for: 0, total: activeCameras.count))] \(activeCameras[0].rawValue.uppercased())")
                            Spacer()
                            Text(recorder.lensFor4K == activeCameras[0] ? "4K" : (activeCameras[0] == .front ? "720P" : "1080P"))
                        }
                        .font(.caption2.bold()).foregroundColor(.white).padding(5)
                        .background(Color.black.opacity(0.6)).cornerRadius(4).padding(6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if activeCameras.indices.contains(1) {
                    ZStack(alignment: .bottomLeading) {
                        CameraViewRepresentable(previewView: recorder.previewView2).clipped()
                        HStack {
                            Text("[\(positionBadge(for: 1, total: activeCameras.count))] \(activeCameras[1].rawValue.uppercased())")
                            Spacer()
                            Text(recorder.lensFor4K == activeCameras[1] ? "4K" : (activeCameras[1] == .front ? "720P" : "1080P"))
                        }
                        .font(.caption2.bold()).foregroundColor(.white).padding(5)
                        .background(Color.black.opacity(0.6)).cornerRadius(4).padding(6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if activeCameras.indices.contains(2) {
                    ZStack(alignment: .bottomLeading) {
                        CameraViewRepresentable(previewView: recorder.previewView3).clipped()
                        HStack {
                            Text("[\(positionBadge(for: 2, total: activeCameras.count))] \(activeCameras[2].rawValue.uppercased())")
                            Spacer()
                            Text(recorder.lensFor4K == activeCameras[2] ? "4K" : "1080P")
                        }
                        .font(.caption2.bold()).foregroundColor(.white).padding(5)
                        .background(Color.black.opacity(0.6)).cornerRadius(4).padding(6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Controls Overlay
            VStack {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        // Flash Button
                        Button(action: { recorder.toggleTorch() }) {
                            HStack(spacing: 4) {
                                Image(systemName: recorder.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                                Text(recorder.isTorchOn ? "ON" : "OFF").font(.caption2.bold())
                            }
                            .foregroundColor(recorder.isTorchOn ? .black : .white)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(recorder.isTorchOn ? Color.yellow : Color.black.opacity(0.75))
                            .cornerRadius(8)
                        }

                        Spacer()

                        // 4K Target Selector
                        Button(action: { show4KPicker = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles.tv")
                                Text(recorder.lensFor4K != nil ? "4K: \(recorder.lensFor4K!.rawValue.prefix(5))" : "4K: OFF")
                                    .font(.caption2.bold())
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(recorder.lensFor4K != nil ? Color.purple.opacity(0.85) : Color.gray.opacity(0.75))
                            .cornerRadius(8)
                        }

                        // Lens Selector Button
                        Button(action: {
                            tempSelectedCameras = recorder.selectedCameras
                            showLensPicker = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "camera.badge.ellipsis")
                                Text("LENSES (\(activeCameras.count))").font(.caption2.bold())
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 9).padding(.vertical, 7)
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

                // Shutter Button
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
        // Sheet 1: Lens Selection with explicit Slot Badges (#1 TOP, #2 MIDDLE, #3 BOTTOM)
        .sheet(isPresented: $showLensPicker) {
            NavigationView {
                List {
                    Section(header: Text("Tap in the order you want them stacked (Max 3)")) {
                        ForEach(AvailableCamera.allCases) { cam in
                            HStack {
                                Text(cam.rawValue)
                                    .font(.body)

                                Spacer()

                                if let index = tempSelectedCameras.firstIndex(of: cam) {
                                    let total = tempSelectedCameras.count
                                    let badgeText = positionBadge(for: index, total: total)
                                    
                                    HStack(spacing: 4) {
                                        Text("#\(index + 1) \(badgeText)")
                                            .font(.caption2.bold())
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue)
                                            .cornerRadius(6)

                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let existingIndex = tempSelectedCameras.firstIndex(of: cam) {
                                    if tempSelectedCameras.count > 1 {
                                        tempSelectedCameras.remove(at: existingIndex)
                                    }
                                } else {
                                    if tempSelectedCameras.count < 3 {
                                        tempSelectedCameras.append(cam)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Select & Order Lenses")
                .navigationBarItems(
                    leading: Button("Cancel") { showLensPicker = false },
                    trailing: Button("Apply") {
                        recorder.selectedCameras = tempSelectedCameras
                        recorder.applyCameraSelection()
                        showLensPicker = false
                    }
                    .font(.headline)
                )
            }
        }
        // Sheet 2: Pick Which Lens Records in 4K
        .sheet(isPresented: $show4KPicker) {
            NavigationView {
                List {
                    Section(header: Text("Choose ONE Rear Lens for 4K")) {
                        HStack {
                            Text("No 4K (All 1080p - Lowest Load)")
                            Spacer()
                            if recorder.lensFor4K == nil {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.purple)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            recorder.set4KLens(nil)
                            show4KPicker = false
                        }

                        ForEach(recorder.selectedCameras.filter { $0 != .front }) { cam in
                            HStack {
                                Text("\(cam.rawValue) in 4K")
                                Spacer()
                                if recorder.lensFor4K == cam {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.purple)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                recorder.set4KLens(cam)
                                show4KPicker = false
                            }
                        }
                    }
                }
                .navigationTitle("4K Lens Selector")
                .navigationBarItems(trailing: Button("Done") { show4KPicker = false })
            }
        }
        .onAppear {
            recorder.startCameraSetup()
        }
    }
}