import SwiftUI
import AVFoundation

struct IncomingCallView: View {
    let callerName: String
    let callType: String // "语音通话" 或 "视频通话"
    var onAccept: () -> Void
    var onReject: () -> Void
    
    @State private var isAnimating = false
    @State private var audioPlayer: AVAudioPlayer?
    
    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0.8), Color.blue.opacity(0.6)]), startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            VStack(spacing: 40) {
                Spacer()
                
                // 头像
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 120, height: 120)
                    .foregroundColor(.white)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)
                    .animation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isAnimating)
                
                VStack(spacing: 10) {
                    Text(callerName)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("正在邀请你进行\(callType)...")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Spacer()
                
                // 操作按钮
                HStack(spacing: 80) {
                    // 挂断按钮
                    Button(action: {
                        stopRingtone()
                        onReject()
                    }) {
                        VStack {
                            Image(systemName: "phone.down.circle.fill")
                                .resizable()
                                .frame(width: 70, height: 70)
                                .foregroundColor(.red)
                            Text("拒绝")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                    }
                    
                    // 接听按钮
                    Button(action: {
                        stopRingtone()
                        onAccept()
                    }) {
                        VStack {
                            Image(systemName: "phone.circle.fill")
                                .resizable()
                                .frame(width: 70, height: 70)
                                .foregroundColor(.green)
                            Text("接听")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            isAnimating = true
            startRingtone()
        }
        .onDisappear {
            stopRingtone()
        }
    }
    
    private func startRingtone() {
        // 播放系统默认来电铃声
        guard let url = Bundle.main.url(forResource: "ringtone", withExtension: "mp3") else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1 // 循环播放
            audioPlayer?.play()
        } catch {
            print("播放铃声失败: \(error)")
        }
    }
    
    private func stopRingtone() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}

struct IncomingCallView_Previews: PreviewProvider {
    static var previews: some View {
        IncomingCallView(callerName: "张三", callType: "视频通话", onAccept: {}, onReject: {})
    }
}
