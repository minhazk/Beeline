import SwiftUI

/// Puts the next trains from a station on the Lock Screen, or takes them off again.
struct NextTrainButton: View {
    var key: String
    var mode: LegMode
    /// Short, for a row of buttons: "Next train".
    var compact = false
    /// What to follow, built when tapped (it asks TfL which line and stations these are).
    var request: @MainActor () async -> NextTrains.Request

    @State private var starting = false
    private var trains: NextTrains { .shared }

    var body: some View {
        let on = trains.isShowing(key)
        let noun = mode == .tram ? "tram" : "train"
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if on {
                    trains.stop()
                    return
                }
                starting = true
                Task {
                    trains.start(await request())
                    starting = false
                }
            } label: {
                HStack(spacing: 6) {
                    if starting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: on ? "checkmark.circle.fill" : "platter.filled.bottom.iphone")
                    }
                    Text(on ? "On Lock Screen" : compact ? "Next \(noun)" : "Next \(noun)s on Lock Screen").lineLimit(1)
                }
                .font(.headline)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(on ? Theme.live : Theme.tint)
            .disabled(starting)
            .accessibilityHint(on ? "Takes the next \(noun)s off the Lock Screen" : "Shows the next \(noun)s from here on the Lock Screen, live")
            if !compact, let problem = trains.problem, !on {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
