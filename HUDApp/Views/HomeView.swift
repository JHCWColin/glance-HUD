import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var viewModel: BLEViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    headerCard
                    metricGrid
                    messageCard
                    logsCard
                }
                .padding(20)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("GlanceHUD")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .task {
            viewModel.start()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.connectionStatus)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(viewModel.connectedDeviceName)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))
                }

                Spacer()

                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.orange)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 6)
                    )
            }

            Text("Allowed devices: HUD Glasses / XIAO-HUD")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            HStack(spacing: 10) {
                actionButton(title: "Scan", background: Color.white.opacity(0.16)) {
                    viewModel.scanForDevices()
                }

                actionButton(title: "Disconnect", background: Color.red.opacity(0.22)) {
                    viewModel.disconnect()
                }

                actionButton(title: "Refresh Weather", background: Color.cyan.opacity(0.22)) {
                    viewModel.refreshWeather()
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private var metricGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            metricTile(title: "Time", value: viewModel.currentTime)
            metricTile(title: "Date", value: viewModel.currentDate)
            metricTile(title: "Weather", value: viewModel.weatherDisplay)
            metricTile(title: "Battery", value: viewModel.batteryDisplay)
        }
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Message")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            TextField("Hello Colin", text: $viewModel.customMessage)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit {
                    viewModel.sendCustomMessage()
                }

            Button(action: viewModel.sendCustomMessage) {
                Text("Send")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.green.opacity(0.78))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BLE Logs")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.logs) { entry in
                            logRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 180, maxHeight: 260)
                .onChange(of: viewModel.logs.count) { _ in
                    if let lastID = viewModel.logs.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.30))
        )
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.66))

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func actionButton(title: String, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
    }

    private func logRow(entry: BLELogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.timestampText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.60))
                .frame(width: 58, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(color(for: entry.level))
                .frame(width: 40, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func color(for level: BLELogLevel) -> Color {
        switch level {
        case .info:
            return .cyan
        case .success:
            return .green
        case .warning:
            return .yellow
        case .error:
            return .red
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.11, blue: 0.09),
                Color(red: 0.03, green: 0.20, blue: 0.17),
                Color(red: 0.01, green: 0.03, blue: 0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .environmentObject(BLEViewModel())
    }
}
