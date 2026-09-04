//
//  NinebotTestView.swift
//  Minimaal testscherm om de handshake en snelheidsregister te proberen.
//  Vervang "JOUW-STEP-BLE-NAAM" door de naam die je step adverteert.
//

import SwiftUI

struct NinebotTestView: View {
    @StateObject private var viewModel = NinebotTestViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Status: \(viewModel.statusText)")
                .padding()

            Button("Verbinden") {
                viewModel.pair()
            }
            .disabled(viewModel.isBusy)

            Button("Lees snelheidsregister") {
                viewModel.readSpeedRegister()
            }
            .disabled(!viewModel.isAuthenticated)

            if let lastRead = viewModel.lastReadValue {
                Text("Gelezen waarde: \(lastRead)")
            }

            HStack {
                Text("Nieuwe limiet: \(Int(viewModel.speedLimit)) km/u")
                Slider(value: $viewModel.speedLimit, in: 5...25, step: 1)
            }
            .padding(.horizontal)

            Button("Zet sport-modus limiet") {
                viewModel.applySpeedLimit()
            }
            .disabled(!viewModel.isAuthenticated)
        }
        .padding()
    }
}

final class NinebotTestViewModel: ObservableObject {
    @Published var statusText: String = "Niet verbonden"
    @Published var isBusy: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var lastReadValue: String?
    @Published var speedLimit: Double = 20

    private let bleManager = NinebotBLEManager()
    private var session: NinebotSession?

    func pair() {
        isBusy = true
        statusText = "Verbinden..."

        let session = NinebotSession(bleManager: bleManager, deviceName: "JOUW-STEP-BLE-NAAM")
        session.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .idle: self.statusText = "Niet verbonden"
                case .connecting: self.statusText = "Verbinden..."
                case .preComm: self.statusText = "Handshake: PRE_COMM..."
                case .settingPassword: self.statusText = "Handshake: wachtwoord instellen..."
                case .waitingForButtonPress: self.statusText = "Druk nu op de knop van de step!"
                case .authenticating: self.statusText = "Handshake: authenticeren..."
                case .authenticated:
                    self.statusText = "Verbonden en geauthenticeerd"
                    self.isAuthenticated = true
                    self.isBusy = false
                case .failed(let reason):
                    self.statusText = "Mislukt: \(reason)"
                    self.isBusy = false
                }
            }
        }
        self.session = session
        session.pair()
    }

    func readSpeedRegister() {
        session?.readRegister(0x74) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let bytes):
                    self?.lastReadValue = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                case .failure(let error):
                    self?.lastReadValue = "Fout: \(error)"
                }
            }
        }
    }

    func applySpeedLimit() {
        session?.setSportModeSpeedLimit(kmh: speedLimit) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.statusText = "Snelheidslimiet verstuurd"
                case .failure(let error):
                    self?.statusText = "Fout bij versturen: \(error)"
                }
            }
        }
    }
}
