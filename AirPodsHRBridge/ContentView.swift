import SwiftUI
import HealthKit
import CoreBluetooth

@main
struct AirPodsHRBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class HeartRateBridgeManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var heartRate: Int = 0
    @Published var isBroadcasting: Bool = false
    @Published var bluetoothReady: Bool = false

    private var peripheralManager: CBPeripheralManager!
    private var heartRateCharacteristic: CBMutableCharacteristic!
    private let healthStore = HKHealthStore()

    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        requestHealthKitAuthorization()
    }

    private func requestHealthKitAuthorization() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        healthStore.requestAuthorization(toShare: nil, read: [hrType]) { success, _ in
            if success { self.startHeartRateObservation() }
        }
    }

    private func startHeartRateObservation() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let query = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self] _, completionHandler, error in
            if error == nil { self?.fetchLatestHeartRate() }
            completionHandler()
        }
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: hrType, frequency: .immediate) { _, _ in }
    }

    private func fetchLatestHeartRate() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: hrType, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { [weak self] _, results, _ in
            guard let sample = results?.first as? HKQuantitySample else { return }
            let bpm = Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            DispatchQueue.main.async {
                self?.heartRate = bpm
                self?.broadcastHeartRate(bpm)
            }
        }
        healthStore.execute(query)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            bluetoothReady = true
            setupBluetoothService()
        } else {
            bluetoothReady = false
        }
    }

    private func setupBluetoothService() {
        heartRateCharacteristic = CBMutableCharacteristic(
            type: heartRateMeasurementUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: heartRateServiceUUID, isPrimary: true)
        service.characteristics = [heartRateCharacteristic]
        peripheralManager.add(service)
    }

    func toggleBroadcasting() {
        if isBroadcasting {
            peripheralManager.stopAdvertising()
            isBroadcasting = false
        } else {
            guard bluetoothReady else { return }
            peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [heartRateServiceUUID],
                CBAdvertisementDataLocalNameKey: "AirPods HR Bridge"
            ])
            isBroadcasting = true
        }
    }

    private func broadcastHeartRate(_ bpm: Int) {
        guard isBroadcasting, bluetoothReady else { return }
        let bpmValue = UInt8(clamping: bpm)
        let payload = Data([0x00, bpmValue])
        peripheralManager.updateValue(payload, for: heartRateCharacteristic, onSubscribedCentrals: nil)
    }
}

struct ContentView: View {
    @StateObject private var manager = HeartRateBridgeManager()

    var body: some View {
        VStack(spacing: 30) {
            Text("AirPods HR Bridge")
                .font(.title)
                .bold()

            Image(systemName: "heart.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 90, height: 90)
                .foregroundColor(manager.heartRate > 0 ? .red : .gray)

            Text("\(manager.heartRate)")
                .font(.system(size: 64, weight: .bold, design: .rounded)) +
            Text(" BPM")
                .font(.title2)
                .foregroundColor(.secondary)

            Button(action: { manager.toggleBroadcasting() }) {
                Text(manager.isBroadcasting ? "Zastavit vysílání" : "Spustit Bluetooth vysílání")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(manager.isBroadcasting ? Color.red : Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .disabled(!manager.bluetoothReady)

            if manager.isBroadcasting {
                HStack {
                    ProgressView()
                        .padding(.trailing, 5)
                    Text("Vysílám pro ErgData / PM5...")
                        .font(.footnote)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
    }
}
