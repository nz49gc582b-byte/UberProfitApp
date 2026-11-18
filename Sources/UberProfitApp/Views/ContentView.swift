import SwiftUI
import ReplayKit
import AVKit

/// Wrapper UIViewRepresentable para exibir a `AVSampleBufferDisplayLayer` necessária ao Picture-in-Picture
public struct PiPLayerContainerView: UIViewRepresentable {
    public let displayLayer: AVSampleBufferDisplayLayer

    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    public func makeUIView(context: Context) -> PiPHostView {
        let view = PiPHostView()
        view.setDisplayLayer(displayLayer)
        return view
    }

    public func updateUIView(_ uiView: PiPHostView, context: Context) {
        uiView.updateFrame()
    }

    public final class PiPHostView: UIView {
        private weak var hostedLayer: AVSampleBufferDisplayLayer?

        public func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
            hostedLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.addSublayer(layer)
            self.hostedLayer = layer
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            updateFrame()
        }

        public func updateFrame() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Botão nativo do ReplayKit (`RPSystemBroadcastPickerView`) para iniciar/parar a captura de tela em 1 toque
public struct BroadcastPickerRepresentable: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 220, height: 54))
        picker.showsMicrophoneButton = false
        picker.preferredExtension = nil
        return picker
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

@MainActor
public struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()

    public init() {}

    public var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            NavigationStack {
                PanelView(viewModel: viewModel)
            }
            .tabItem { Label(AppSectionTab.operation.rawValue, systemImage: AppSectionTab.operation.icon) }
            .tag(AppSectionTab.operation)

            NavigationStack {
                EarningsView(viewModel: viewModel)
            }
            .tabItem { Label(AppSectionTab.earnings.rawValue, systemImage: AppSectionTab.earnings.icon) }
            .tag(AppSectionTab.earnings)

            NavigationStack {
                HistoryTabView(viewModel: viewModel)
            }
            .tabItem { Label(AppSectionTab.history.rawValue, systemImage: AppSectionTab.history.icon) }
            .tag(AppSectionTab.history)

            NavigationStack {
                SettingsHomeView(viewModel: viewModel)
            }
            .tabItem { Label(AppSectionTab.settings.rawValue, systemImage: AppSectionTab.settings.icon) }
            .tag(AppSectionTab.settings)
        }
        .tint(Theme.accent)
        .onAppear {
            viewModel.startBackgroundServices()
        }
        .sheet(item: $viewModel.selectedRideDetail) { item in
            RideDetailSheet(viewModel: viewModel, ride: item)
        }
        .sheet(isPresented: $viewModel.showAddManualRideSheet) {
            AddManualRideSheetView(viewModel: viewModel)
        }
    }
}
