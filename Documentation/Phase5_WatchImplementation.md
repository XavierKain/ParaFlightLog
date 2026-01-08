# Phase 5: Apple Watch Enhancements - Implementation Guide

## Overview

This document outlines the implementation strategy for Apple Watch enhancements, including improved UI readability and heart rate tracking integration.

---

## 5.1 Improve Watch Display Readability

### Current Issues
- Font sizes may be too small for quick glances during flight
- No color coding for critical metrics
- Layout could be simplified for better readability on small screen

### Improvements Needed

#### File: `ParaFlightLogWatch Watch App/ContentView.swift`

**Font Size Increases:**
```swift
// Current metrics display (example)
Text("\(altitude) m")
    .font(.body)  // TOO SMALL

// Should be:
Text("\(altitude)")
    .font(.system(size: 36, weight: .bold, design: .rounded))
Text("m")
    .font(.caption)
    .foregroundStyle(.secondary)
```

**Color Coding:**
```swift
// Altitude - green when climbing, red when descending
Text("\(altitude) m")
    .foregroundStyle(verticalSpeed > 0 ? .green : .red)

// Duration - blue (primary)
Text(formattedDuration)
    .foregroundStyle(.blue)

// Speed - cyan
Text("\(speed) km/h")
    .foregroundStyle(.cyan)
```

**Simplified Layout:**
- Use VStack with larger spacing
- Remove non-essential info during active flight
- Use full-width metric cards
- Add haptic feedback for altitude milestones

**Complications:**
```swift
// Add complication for active flight
// Shows: Current altitude + duration
struct ActiveFlightComplication: View {
    let altitude: Double
    let duration: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Int(altitude))m")
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)
            Text(duration)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
```

---

## 5.2 Heart Rate Tracking with HealthKit

### Architecture

#### New Model: HRSample
```swift
// Add to Models.swift
struct HRSample: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let bpm: Double

    init(timestamp: Date, bpm: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.bpm = bpm
    }
}
```

#### Update Flight Model
```swift
// Add to Flight class in Models.swift
@Attribute(.externalStorage)
var heartRateData: Data? = nil  // Encoded [HRSample]

var heartRateSamples: [HRSample]? {
    get {
        guard let data = heartRateData else { return nil }
        return try? JSONDecoder().decode([HRSample].self, from: data)
    }
    set {
        heartRateData = try? JSONEncoder().encode(newValue)
    }
}

var averageHeartRate: Double? {
    guard let samples = heartRateSamples, !samples.isEmpty else { return nil }
    return samples.map(\.bpm).reduce(0, +) / Double(samples.count)
}

var maxHeartRate: Double? {
    heartRateSamples?.map(\.bpm).max()
}
```

---

### 5.2.1 Watch Implementation

#### File: `ParaFlightLogWatch Watch App/FlightSessionManager.swift`

**Step 1: Import HealthKit**
```swift
import HealthKit
import Combine
```

**Step 2: Add HealthKit Properties**
```swift
class FlightSessionManager: NSObject, ObservableObject {
    // Existing properties...

    // HealthKit
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var heartRateSamples: [HRSample] = []

    @Published var currentHeartRate: Double = 0
    @Published var averageHeartRate: Double = 0
    @Published var isTrackingHeartRate = false

    // Settings
    @AppStorage("enableHeartRateTracking") private var enableHeartRateTracking = true
    @AppStorage("heartRateSampleInterval") private var heartRateSampleInterval = 5.0  // seconds
}
```

**Step 3: Request HealthKit Authorization**
```swift
func requestHealthKitAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
        throw HealthKitError.notAvailable
    }

    let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!

    let typesToRead: Set<HKObjectType> = [heartRateType]

    try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
}
```

**Step 4: Start Heart Rate Tracking**
```swift
func startHeartRateTracking() async throws {
    guard enableHeartRateTracking else { return }

    // Create workout configuration
    let config = HKWorkoutConfiguration()
    config.activityType = .other  // Or .airSports if available
    config.locationType = .outdoor

    // Start workout session
    workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
    workoutSession?.delegate = self

    // Start session
    workoutSession?.startActivity(with: Date())

    // Create streaming query for heart rate
    let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    let predicate = HKQuery.predicateForSamples(
        withStart: Date(),
        end: nil,
        options: .strictStartDate
    )

    heartRateQuery = HKAnchoredObjectQuery(
        type: heartRateType,
        predicate: predicate,
        anchor: nil,
        limit: HKObjectQueryNoLimit
    ) { [weak self] query, samples, deletedObjects, anchor, error in
        self?.processHeartRateSamples(samples)
    }

    heartRateQuery?.updateHandler = { [weak self] query, samples, deletedObjects, anchor, error in
        self?.processHeartRateSamples(samples)
    }

    healthStore.execute(heartRateQuery!)
    isTrackingHeartRate = true
}

private func processHeartRateSamples(_ samples: [HKSample]?) {
    guard let heartRateSamples = samples as? [HKQuantitySample] else { return }

    for sample in heartRateSamples {
        let bpm = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))

        let hrSample = HRSample(timestamp: sample.startDate, bpm: bpm)
        self.heartRateSamples.append(hrSample)

        // Update current HR on main thread
        DispatchQueue.main.async {
            self.currentHeartRate = bpm
            self.calculateAverageHeartRate()
        }
    }
}

private func calculateAverageHeartRate() {
    guard !heartRateSamples.isEmpty else {
        averageHeartRate = 0
        return
    }
    averageHeartRate = heartRateSamples.map(\.bpm).reduce(0, +) / Double(heartRateSamples.count)
}
```

**Step 5: Stop Heart Rate Tracking**
```swift
func stopHeartRateTracking() {
    if let query = heartRateQuery {
        healthStore.stop(query)
        heartRateQuery = nil
    }

    workoutSession?.end()
    workoutSession = nil

    isTrackingHeartRate = false
}
```

**Step 6: Integrate with Flight Recording**
```swift
// In the flight end function:
func endFlight() {
    // ... existing flight end logic ...

    // Save heart rate data
    if !heartRateSamples.isEmpty {
        currentFlight.heartRateSamples = heartRateSamples
    }

    // Stop HR tracking
    stopHeartRateTracking()
}
```

**Step 7: Update Watch UI**
```swift
// In Watch ContentView during active flight
if sessionManager.isTrackingHeartRate {
    HStack {
        Image(systemName: "heart.fill")
            .foregroundStyle(.red)
        Text("\(Int(sessionManager.currentHeartRate))")
            .font(.system(size: 28, weight: .bold, design: .rounded))
        Text("BPM")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

---

### 5.2.2 iPhone Implementation: Heart Rate Chart

#### File: `Views/FlightsViews.swift` (FlightDetailView)

**Add Heart Rate Section (if data available)**
```swift
// In FlightDetailView body, after GPS map section:
if let hrSamples = flight.heartRateSamples, !hrSamples.isEmpty {
    Section("Fréquence Cardiaque") {
        HeartRateChartView(samples: hrSamples)
            .frame(height: 200)

        HStack {
            StatLabel(icon: "heart.fill", label: "Moyenne", value: "\(Int(flight.averageHeartRate ?? 0)) BPM", color: .red)
            Divider()
            StatLabel(icon: "heart.circle.fill", label: "Maximum", value: "\(Int(flight.maxHeartRate ?? 0)) BPM", color: .red)
        }
    }
}
```

#### New File: `Views/HeartRateChartView.swift`

```swift
import SwiftUI
import Charts

struct HeartRateChartView: View {
    let samples: [HRSample]

    // HR zones (example - can be customized per user)
    private let zones: [(name: String, min: Double, max: Double, color: Color)] = [
        ("Repos", 50, 100, .gray),
        ("Brûlage graisse", 100, 140, .green),
        ("Cardio", 140, 160, .orange),
        ("Pic", 160, 220, .red)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                // Plot heart rate line
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("BPM", sample.bpm)
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
                }

                // Zone backgrounds
                ForEach(zones, id: \.name) { zone in
                    RectangleMark(
                        yStart: .value("Min", zone.min),
                        yEnd: .value("Max", zone.max)
                    )
                    .foregroundStyle(zone.color.opacity(0.1))
                    .annotation(position: .leading) {
                        Text(zone.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }

            // Legend
            HStack(spacing: 16) {
                ForEach(zones, id: \.name) { zone in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(zone.color)
                            .frame(width: 8, height: 8)
                        Text(zone.name)
                            .font(.caption2)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
```

---

### 5.2.3 Sync Heart Rate Data to Cloud

#### Update FlightSyncService

```swift
// In FlightSyncService.uploadFlight()
// Already handles all @Attribute data automatically via SwiftData
// Just ensure heartRateData is being saved in SwiftData

// Optionally, add size check for large HR datasets
func optimizeHeartRateData(samples: [HRSample]) -> [HRSample] {
    // If >1000 samples, downsample to every Nth sample
    guard samples.count > 1000 else { return samples }

    let stride = samples.count / 500  // Keep ~500 samples
    return samples.enumerated()
        .filter { $0.offset % stride == 0 }
        .map { $0.element }
}
```

---

### 5.2.4 Settings & Privacy

#### Add to SettingsView (iOS)

```swift
Section("Fréquence Cardiaque") {
    Toggle("Suivre la fréquence cardiaque", isOn: $enableHeartRateTracking)
        .onChange(of: enableHeartRateTracking) { _, newValue in
            if newValue {
                Task {
                    try? await requestHealthKitAuth()
                }
            }
        }

    if enableHeartRateTracking {
        Picker("Fréquence d'échantillonnage", selection: $heartRateSampleInterval) {
            Text("5 secondes").tag(5.0)
            Text("10 secondes (économie batterie)").tag(10.0)
            Text("15 secondes").tag(15.0)
        }
    }
}
.disabled(!HKHealthStore.isHealthDataAvailable())
```

#### Privacy: Info.plist Updates

**Required for both iOS and watchOS targets:**

```xml
<key>NSHealthShareUsageDescription</key>
<string>SoarX utilise vos données de fréquence cardiaque pour enrichir vos statistiques de vol et vous aider à comprendre votre effort physique pendant le vol.</string>

<key>NSHealthUpdateUsageDescription</key>
<string>SoarX enregistre vos sessions de vol comme activités physiques dans l'app Santé.</string>
```

---

## 5.3 Testing Checklist

### Watch Readability
- [ ] Test on all Watch sizes (40mm, 41mm, 44mm, 45mm, 49mm)
- [ ] Verify readability in bright sunlight (max brightness)
- [ ] Test color contrast in both light and dark mode
- [ ] Verify haptic feedback works
- [ ] Test complications display correctly

### Heart Rate Tracking
- [ ] HealthKit authorization flow works on first launch
- [ ] Heart rate updates in real-time during flight
- [ ] Data saves correctly to Flight model
- [ ] Syncs to iPhone successfully
- [ ] Chart displays correctly on iPhone
- [ ] Battery impact is acceptable (<15% extra drain)
- [ ] Works with Apple Watch in Airplane Mode + GPS
- [ ] Handles edge cases (no HR sensor, sensor failure, authorization denied)

---

## 5.4 Performance Optimization

### Battery Considerations
- Default sample interval: 5 seconds (balance between detail and battery)
- Option for 10-15 second intervals for longer flights
- Stop HR tracking if battery <20%
- Use HKWorkoutSession (optimized by Apple for workouts)

### Data Size
- ~720 samples for 1-hour flight at 5-second intervals
- Each sample: ~24 bytes (UUID + Date + Double)
- Total: ~17KB per flight (negligible)
- Downsample to ~500 samples if >1000 collected

---

## 5.5 Future Enhancements (Backlog)

- [ ] Heart rate zones customized per user (age, fitness level)
- [ ] Alerts for abnormal heart rate (too high/low)
- [ ] Export HR data to Apple Health as workout
- [ ] Correlation analysis (altitude vs HR, speed vs HR)
- [ ] Recovery time calculation post-flight
- [ ] VO2 max estimation integration

---

## Implementation Status

**Current Status**: Design phase complete, ready for implementation

**Blockers**:
- Watch App icon issue must be resolved before building
- Requires testing with physical Apple Watch hardware

**Next Steps**:
1. Resolve Watch app icon issue
2. Implement HealthKit authorization flow
3. Integrate HR tracking into FlightSessionManager
4. Update UI for readability improvements
5. Test on device
6. Implement iPhone chart view

---

*Last Updated: 2026-01-07*
*Phase 5 Implementation Guide - SoarX*
