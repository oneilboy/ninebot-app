//
//  NinebotSession.swift
//  Orkestreert de 3-fase auth-handshake (PRE_COMM → SET_PWD → AUTH) en biedt
//  daarna encrypted read/write van registers, incl. de sport-modus snelheidslimiet.
//
//  Gebruik:
//    let session = NinebotSession(bleManager: myNinebotBLEManager, deviceName: "MIScooterXXXX")
//    session.onStateChange = { state in ... }   // toon UI-feedback ("druk op de knop", etc.)
//    session.pair()
//    // eenmaal .authenticated:
//    session.setSportModeSpeedLimit(kmh: 25) { result in ... }
//
//  LET OP — lees dit voor je test:
//  - Bij de EERSTE koppeling moet je (net als bij de officiële app) binnen ~5-60s
//    een fysieke knop op de step indrukken (SET_PWD-fase, zie onState .waitingForButtonPress).
//  - Deze implementatie volgt de gepubliceerde protocolspecificatie 1-op-1, maar is
//    NIET getest tegen een echte E2 Pro. Test eerst met een LEES-commando (bv. huidige
//    snelheidslimiet uitlezen) voor je een schrijfcommando stuurt.
//  - Enkel gebruiken met je eigen voertuig — de handshake vereist toch de fysieke
//    knop op de step, dus dit werkt sowieso niet op andermans step zonder toegang
//    tot het toestel zelf.
//

import Foundation
import CoreBluetooth
import CryptoKit

enum NinebotSessionState: Equatable {
    case idle
    case connecting
    case preComm
    case settingPassword
    case waitingForButtonPress
    case authenticating
    case authenticated
    case failed(String)
}

final class NinebotSession {

    private let bleManager: NinebotBLEManager
    private let deviceName: String
    private let boardTarget: UInt8 = 0x04   // BLE board, zoals gedocumenteerd

    private var key1: [UInt8] = []
    private var key2: [UInt8]? = nil
    private var authParam: [UInt8] = []
    private var serialNumber: [UInt8] = []
    private var sessionPassword: [UInt8] = []
    private var counter: UInt32 = 0
    private var lastReceivedCounter: UInt32 = 0

    private var pendingResponseHandler: ((Result<[UInt8], Error>) -> Void)?
    private var buttonPressRetryTimer: Timer?
    private let buttonPressTimeout: TimeInterval = 60

    var onStateChange: ((NinebotSessionState) -> Void)?
    private(set) var state: NinebotSessionState = .idle {
        didSet { onStateChange?(state) }
    }

    init(bleManager: NinebotBLEManager, deviceName: String) {
        self.bleManager = bleManager
        self.deviceName = deviceName
        self.bleManager.delegate = self
        self.bleManager.onCharacteristicsReady = { [weak self] in
            self?.startPreComm()
        }
    }

    // MARK: - Publieke flow

    func pair() {
        counter = 0
        lastReceivedCounter = 0
        state = .connecting
        bleManager.startScanning()
    }

    /// Leest een register (zonder wijziging) — gebruik dit eerst om te verifiëren
    /// dat de handshake werkt en welk register overeenkomt met de snelheidslimiet.
    /// cmd = READ (0x01), index = registeradres, data = [aantal te lezen bytes]
    func readRegister(_ register: UInt8, byteCount: UInt8 = 2, completion: @escaping (Result<[UInt8], Error>) -> Void) {
        guard state == .authenticated else {
            completion(.failure(NinebotSessionError.notAuthenticated))
            return
        }
        sendEncryptedCommand(cmd: 0x01, index: register, data: [byteCount], completion: completion)
    }

    /// cmd = WRITE-met-bevestiging (0x02), index = registeradres, data = nieuwe waarde (little-endian)
    func writeRegister(_ register: UInt8, data: [UInt8], completion: @escaping (Result<[UInt8], Error>) -> Void) {
        guard state == .authenticated else {
            completion(.failure(NinebotSessionError.notAuthenticated))
            return
        }
        sendEncryptedCommand(cmd: 0x02, index: register, data: data, completion: completion)
    }

    /// Zet de snelheidslimiet van sport-modus.
    /// - Parameter kmh: gewenste limiet in km/u
    /// - Important: verifieer eerst via readRegister welk register/eenheid je toestel
    ///   effectief gebruikt — 0x74 in m/u is gebaseerd op het oudere Ninebot One-protocol
    ///   en is NIET expliciet bevestigd voor de E2 Pro's Encryption2-protocol.
    func setSportModeSpeedLimit(kmh: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        let mPerHour = UInt16(kmh * 1000)
        let data: [UInt8] = [UInt8(mPerHour & 0xFF), UInt8((mPerHour >> 8) & 0xFF)]
        writeRegister(0x74, data: data) { result in
            switch result {
            case .success: completion(.success(()))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    // MARK: - Frame bouwen/versturen

    private func buildPlaintextFrame(cmd: UInt8, index: UInt8, data: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x5A, 0xA5, UInt8(data.count & 0xFF)]
        frame.append(0x3E)          // source = telefoon
        frame.append(boardTarget)   // target = BLE board
        frame.append(cmd)
        frame.append(index)
        frame.append(contentsOf: data)
        return frame
    }

    private func sendEncryptedCommand(cmd: UInt8, index: UInt8, data: [UInt8],
                                       completion: @escaping (Result<[UInt8], Error>) -> Void) {
        let plaintext = buildPlaintextFrame(cmd: cmd, index: index, data: data)
        let key = NinebotCrypto.deriveKey(key1: sessionPassword, key2: authParam)
        counter += 1
        let frame = NinebotCrypto.encryptSN(key: key, plaintext: plaintext, counter: counter, auth: authParam)
        pendingResponseHandler = { result in
            switch result {
            case .success(let plaintextResponse):
                // plaintextResponse = [0x5A,0xA5,LEN, srcBoard, dest, cmd, index, data...]
                let payload = plaintextResponse.count > 7 ? Array(plaintextResponse.dropFirst(7)) : []
                completion(.success(payload))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        bleManager.sendRaw(Data(frame))
    }

    // MARK: - Handshake fasen

    private func startPreComm() {
        state = .preComm
        key1 = Array(deviceName.utf8)
        key2 = nil
        counter = 0

        let plaintext = buildPlaintextFrame(cmd: 0x5B, index: 0x00, data: [])
        let key = NinebotCrypto.deriveKey(key1: key1, key2: key2)
        let frame = NinebotCrypto.encryptNonSN(key: key, plaintext: plaintext)

        pendingResponseHandler = { [weak self] result in
            self?.handlePreCommResponse(result)
        }
        bleManager.sendRaw(Data(frame))
    }

    private func handlePreCommResponse(_ result: Result<[UInt8], Error>) {
        guard case .success(let plaintext) = result, plaintext.count >= 7 + 30 else {
            state = .failed("PRE_COMM: ongeldig antwoord")
            return
        }
        let data = Array(plaintext.dropFirst(7))
        authParam = Array(data.prefix(16))
        serialNumber = Array(data[16..<30])
        counter = 1   // SN mode vanaf nu, counter start op 1 (eerste encrypt -> 2)
        startSetPassword()
    }

    private func startSetPassword() {
        state = .settingPassword
        key1 = Array(deviceName.utf8)
        key2 = authParam

        sessionPassword = generateSessionPassword(authParam: authParam)

        let plaintext = buildPlaintextFrame(cmd: 0x5C, index: 0x00, data: sessionPassword)
        let key = NinebotCrypto.deriveKey(key1: key1, key2: key2)
        counter += 1
        let frame = NinebotCrypto.encryptSN(key: key, plaintext: plaintext, counter: counter, auth: authParam)

        pendingResponseHandler = { [weak self] result in
            self?.handleSetPasswordResponse(result)
        }
        bleManager.sendRaw(Data(frame))
        scheduleButtonPressRetry()
    }

    private func scheduleButtonPressRetry() {
        buttonPressRetryTimer?.invalidate()
        state = .waitingForButtonPress
        buttonPressRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard self.state == .waitingForButtonPress else { timer.invalidate(); return }
            // her-verstuur SET_PWD met hetzelfde wachtwoord tot bevestigd of timeout
            let plaintext = self.buildPlaintextFrame(cmd: 0x5C, index: 0x00, data: self.sessionPassword)
            let key = NinebotCrypto.deriveKey(key1: self.key1, key2: self.key2)
            self.counter += 1
            let frame = NinebotCrypto.encryptSN(key: key, plaintext: plaintext, counter: self.counter, auth: self.authParam)
            self.bleManager.sendRaw(Data(frame))
        }
    }

    private func handleSetPasswordResponse(_ result: Result<[UInt8], Error>) {
        guard case .success(let plaintext) = result, plaintext.count >= 7 else {
            state = .failed("SET_PWD: ongeldig antwoord")
            return
        }
        let index = plaintext[6]
        if index == 1 {
            buttonPressRetryTimer?.invalidate()
            startAuth()
        }
        // index == 0: nog wachten op knopdruk, retry-timer doet zijn werk
    }

    private func startAuth() {
        state = .authenticating
        key1 = sessionPassword
        key2 = authParam

        let plaintext = buildPlaintextFrame(cmd: 0x5D, index: 0x00, data: serialNumber)
        let key = NinebotCrypto.deriveKey(key1: key1, key2: key2)
        counter += 1
        let frame = NinebotCrypto.encryptSN(key: key, plaintext: plaintext, counter: counter, auth: authParam)

        pendingResponseHandler = { [weak self] result in
            self?.handleAuthResponse(result)
        }
        bleManager.sendRaw(Data(frame))
    }

    private func handleAuthResponse(_ result: Result<[UInt8], Error>) {
        guard case .success(let plaintext) = result, plaintext.count >= 7 else {
            state = .failed("AUTH: ongeldig antwoord")
            return
        }
        let index = plaintext[6]
        if index == 1 {
            state = .authenticated
        } else {
            state = .failed("AUTH: geweigerd door voertuig")
        }
    }

    // MARK: - Wachtwoordgeneratie (Java LCG + SHA-256, zie authentication docs)

    private func generateSessionPassword(authParam: [UInt8]) -> [UInt8] {
        let timeMs = Int64(Date().timeIntervalSince1970 * 1000)

        var seedValue: Int32 = 0
        for (i, b) in authParam.enumerated() {
            let signedByte: Int32 = b < 128 ? Int32(b) : Int32(b) - 256
            let shift = (i % 8) * 8
            let val = signedByte << Int32(shift & 31)
            seedValue = seedValue &+ val
        }
        let seed = timeMs &+ Int64(seedValue)

        var rng = JavaRandom(seed: seed)
        let randomBytes = rng.nextBytes(count: 16)

        let hash = SHA256Helper.hash(Data(randomBytes))
        return Array(hash.prefix(16))
    }
}

enum NinebotSessionError: Error {
    case notAuthenticated
    case timeout
}

// MARK: - CoreBluetooth koppeling

extension NinebotSession: NinebotBLEManagerDelegate {

    func ninebotManager(_ manager: NinebotBLEManager, didDiscover peripheral: CBPeripheral, rssi: NSNumber) {
        guard peripheral.name == deviceName else { return }
        manager.connect(to: peripheral)
    }

    func ninebotManager(_ manager: NinebotBLEManager, didConnect peripheral: CBPeripheral) {
        // Handshake start pas via onCharacteristicsReady (zie init), zodra write-
        // en notify-characteristic effectief gevonden zijn — niet hier al.
    }

    func ninebotManager(_ manager: NinebotBLEManager, didDisconnect peripheral: CBPeripheral, error: Error?) {
        buttonPressRetryTimer?.invalidate()
        if state != .authenticated {
            state = .failed("Verbinding verbroken tijdens handshake")
        } else {
            state = .idle
        }
    }

    func ninebotManager(_ manager: NinebotBLEManager, didReceiveRawData data: Data) {
        let key: [UInt8]
        switch state {
        case .preComm:
            key = NinebotCrypto.deriveKey(key1: key1, key2: key2)
        case .settingPassword, .waitingForButtonPress:
            key = NinebotCrypto.deriveKey(key1: key1, key2: key2)
        case .authenticating:
            key = NinebotCrypto.deriveKey(key1: sessionPassword, key2: authParam)
        case .authenticated:
            key = NinebotCrypto.deriveKey(key1: sessionPassword, key2: authParam)
        default:
            return
        }

        do {
            let (plaintext, _) = try NinebotCrypto.decrypt(key: key, ciphertext: Array(data), auth: authParam)
            pendingResponseHandler?(.success(plaintext))
        } catch {
            pendingResponseHandler?(.failure(error))
        }
    }

    func ninebotManager(_ manager: NinebotBLEManager, didFailWithError error: Error) {
        state = .failed(error.localizedDescription)
    }
}

// MARK: - SHA-256 helper (CryptoKit wrapper, voor leesbaarheid hierboven)

enum SHA256Helper {
    static func hash(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
