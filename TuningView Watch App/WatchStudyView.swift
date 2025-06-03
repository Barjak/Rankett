import SwiftUI
import WatchConnectivity

// Decode the same payload you encoded above
struct WatchPayload: Codable {
        let hpsFundamental: Float
        let timestamp: TimeInterval
}

final class WatchStudyModel: NSObject, ObservableObject, WCSessionDelegate {
        @Published var latestFundamental: Float? = nil
        
        override init() {
                super.init()
                if WCSession.isSupported() {
                        let session = WCSession.default
                        session.delegate = self
                        session.activate()
                }
        }
        
        func session(_ session: WCSession,
                     activationDidCompleteWith activationState: WCSessionActivationState,
                     error: Error?)
        {
                // No‐op
        }
        
        func session(_ session: WCSession,
                     didReceiveMessage message: [String : Any])
        {
                if let rawData = message["hpsFundamental"] as? Data {
                        if let payload = try? JSONDecoder().decode(WatchPayload.self, from: rawData) {
                                DispatchQueue.main.async {
                                        self.latestFundamental = payload.hpsFundamental
                                        print("Received")
                                }
                        }
                }
        }
}

struct WatchStudyView: View {
        @StateObject private var model = WatchStudyModel()
        
        var body: some View {
                VStack {
                        if let f = model.latestFundamental {
                                Text("\(f, specifier: "%.1f") Hz")
                                        .font(.system(size: 22, weight: .medium))
                        } else {
                                Text("Waiting for data…")
                                        .font(.system(size: 16))
                        }
                }
                .onAppear {
                        // WCSession is already activated in WatchStudyModel.init()
                }
        }
}
