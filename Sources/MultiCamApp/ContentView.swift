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

            VStack(spacing: 2) {
                CameraViewRepresentable(previewView: recorder.backPreviewView)
                    .clipped()
                CameraViewRepresentable(previewView: recorder.frontPreviewView)
                    .clipped()
            }

            VStack {
                if !recorder.statusMessage.isEmpty {
                    Text(recorder.statusMessage)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.top, 40)
                }

                Spacer()

                Button(action: {
                    recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
                }) {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.white)
                        .frame(width: 70, height: 70)
                        .overlay(Circle().stroke(Color.black, lineWidth: 3))
                }
                .padding(.bottom, 30)
            }
        }
    }
}