import SwiftUI
import CoreMIDI
import AppKit
import UniformTypeIdentifiers

@main
struct MIDIHostApp: App {
    @StateObject private var session = MIDISession()

    init() {
        // Swift Package Manager launches the executable directly. Explicitly
        // register it as a normal foreground app so it participates in Cmd-Tab
        // and appears in the Dock like a bundled macOS application.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

struct MIDIPort: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let kind: PortKind
    let endpoint: MIDIEndpointRef

    enum PortKind: String, Hashable {
        case source = "Input"
        case destination = "Output"
    }
}

struct MIDIRoute: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceID: String
    let destinationID: String
    var sourceChannel: Int?
    var destinationChannel: Int?
}

struct MIDIPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var routes: [MIDIRoute]
    // Optional keeps presets created before device visibility was persisted loadable.
    var enabledSourceIDs: [String]?
    var enabledDestinationIDs: [String]?
}

final class MIDISession: ObservableObject {
    @Published private(set) var sources: [MIDIPort] = []
    @Published private(set) var destinations: [MIDIPort] = []
    @Published private(set) var enabledSourceIDs: Set<String> = []
    @Published private(set) var enabledDestinationIDs: Set<String> = []
    @Published private(set) var routes: [MIDIRoute] = []
    @Published private(set) var lastMessage = "Waiting for MIDI…"
    @Published private(set) var messageCount = 0
    @Published private(set) var activeRoutes: Set<UUID> = []
    @Published private(set) var presets: [MIDIPreset] = []
    @Published private(set) var currentPresetID: UUID?
    @Published private(set) var startupPresetID: UUID?

    private let presetStorageKey = "MIDIHost.presets"
    private let startupPresetStorageKey = "MIDIHost.startupPreset"
    private let enabledSourceStorageKey = "MIDIHost.enabledSourceIDs"
    private let enabledDestinationStorageKey = "MIDIHost.enabledDestinationIDs"

    private var client = MIDIClientRef()
    private var outputPorts: [String: MIDIPortRef] = [:]
    private var routeBindings: [UUID: RouteBinding] = [:]
    private var hasInitializedDeviceVisibility = false
    private let activityLock = NSLock()
    private var activityDispatchPending: Set<UUID> = []
    private var heldNotes: [UUID: Set<Int>] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: presetStorageKey), let stored = try? JSONDecoder().decode([MIDIPreset].self, from: data) {
            presets = stored
        }
        if let storedSourceIDs = UserDefaults.standard.array(forKey: enabledSourceStorageKey) as? [String] {
            enabledSourceIDs = Set(storedSourceIDs)
        }
        if let storedDestinationIDs = UserDefaults.standard.array(forKey: enabledDestinationStorageKey) as? [String] {
            enabledDestinationIDs = Set(storedDestinationIDs)
        }
        startupPresetID = UserDefaults.standard.string(forKey: startupPresetStorageKey).flatMap(UUID.init)
        refresh()
        MIDIClientCreate("MIDI Host" as CFString, nil, nil, &client)
        refresh()
        if let startupPresetID, let startupPreset = presets.first(where: { $0.id == startupPresetID }) {
            loadPreset(startupPreset)
        }
    }

    deinit {
        for binding in routeBindings.values where binding.inputPort != 0 {
            MIDIPortDispose(binding.inputPort)
        }
        for outputPort in outputPorts.values where outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if client != 0 { MIDIClientDispose(client) }
    }

    func refresh() {
        sources = endpoints(for: MIDIGetNumberOfSources(), getter: MIDIGetSource, kind: .source)
        destinations = endpoints(for: MIDIGetNumberOfDestinations(), getter: MIDIGetDestination, kind: .destination)
        let sourceIDs = Set(sources.map(\.id))
        let destinationIDs = Set(destinations.map(\.id))
        if !hasInitializedDeviceVisibility {
            if UserDefaults.standard.object(forKey: enabledSourceStorageKey) == nil {
                enabledSourceIDs = sourceIDs
            } else {
                enabledSourceIDs = enabledSourceIDs.intersection(sourceIDs)
            }
            if UserDefaults.standard.object(forKey: enabledDestinationStorageKey) == nil {
                enabledDestinationIDs = destinationIDs
            } else {
                enabledDestinationIDs = enabledDestinationIDs.intersection(destinationIDs)
            }
            hasInitializedDeviceVisibility = true
        } else {
            enabledSourceIDs = enabledSourceIDs.intersection(sourceIDs)
            enabledDestinationIDs = enabledDestinationIDs.intersection(destinationIDs)
        }
    }

    var enabledSources: [MIDIPort] { sources.filter { enabledSourceIDs.contains($0.id) } }
    var enabledDestinations: [MIDIPort] { destinations.filter { enabledDestinationIDs.contains($0.id) } }

    func setSourceEnabled(_ port: MIDIPort, enabled: Bool) {
        if enabled { enabledSourceIDs.insert(port.id) } else { enabledSourceIDs.remove(port.id) }
        persistDeviceVisibility()
    }

    func setDestinationEnabled(_ port: MIDIPort, enabled: Bool) {
        if enabled { enabledDestinationIDs.insert(port.id) } else { enabledDestinationIDs.remove(port.id) }
        persistDeviceVisibility()
    }

    func setVisibleDevices(sourceIDs: [String]?, destinationIDs: [String]?) {
        if let sourceIDs { enabledSourceIDs = Set(sourceIDs).intersection(sources.map(\.id)) }
        if let destinationIDs { enabledDestinationIDs = Set(destinationIDs).intersection(destinations.map(\.id)) }
        persistDeviceVisibility()
    }

    func savePreset(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        presets.removeAll { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
        presets.append(MIDIPreset(id: UUID(), name: trimmedName, routes: routes,
                                  enabledSourceIDs: Array(enabledSourceIDs),
                                  enabledDestinationIDs: Array(enabledDestinationIDs)))
        currentPresetID = presets.last?.id
        persistPresets()
    }

    func updateCurrentPreset() {
        guard let currentPresetID, let index = presets.firstIndex(where: { $0.id == currentPresetID }) else { return }
        presets[index].routes = routes
        presets[index].enabledSourceIDs = Array(enabledSourceIDs)
        presets[index].enabledDestinationIDs = Array(enabledDestinationIDs)
        persistPresets()
        lastMessage = "Updated preset · \(presets[index].name)"
    }

    func renamePreset(_ preset: MIDIPreset, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = trimmedName
        persistPresets()
        lastMessage = "Renamed preset · \(trimmedName)"
    }

    func setStartupPreset(_ preset: MIDIPreset) {
        startupPresetID = preset.id
        UserDefaults.standard.set(preset.id.uuidString, forKey: startupPresetStorageKey)
        lastMessage = "Startup preset set · \(preset.name)"
    }

    func loadPreset(_ preset: MIDIPreset) {
        setVisibleDevices(sourceIDs: preset.enabledSourceIDs, destinationIDs: preset.enabledDestinationIDs)
        let existingRoutes = routes
        for route in existingRoutes {
            disconnect(route)
        }
        var loadedCount = 0
        for savedRoute in preset.routes {
            guard let source = sources.first(where: { $0.id == savedRoute.sourceID }),
                  let destination = destinations.first(where: { $0.id == savedRoute.destinationID }) else { continue }
            guard let loadedRoute = connect(source: source, destination: destination) else { continue }
            setRouteChannels(routeID: loadedRoute.id, sourceChannel: savedRoute.sourceChannel, destinationChannel: savedRoute.destinationChannel)
            loadedCount += 1
        }
        lastMessage = "Loaded \(preset.name) · \(loadedCount) of \(preset.routes.count) routes"
        currentPresetID = preset.id
    }

    func deletePreset(_ preset: MIDIPreset) {
        presets.removeAll { $0.id == preset.id }
        if currentPresetID == preset.id { currentPresetID = nil }
        if startupPresetID == preset.id {
            startupPresetID = nil
            UserDefaults.standard.removeObject(forKey: startupPresetStorageKey)
        }
        persistPresets()
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetStorageKey)
        }
    }

    func setAllSourcesEnabled(_ enabled: Bool) {
        enabledSourceIDs = enabled ? Set(sources.map(\.id)) : []
        persistDeviceVisibility()
    }

    func setAllDestinationsEnabled(_ enabled: Bool) {
        enabledDestinationIDs = enabled ? Set(destinations.map(\.id)) : []
        persistDeviceVisibility()
    }

    private func persistDeviceVisibility() {
        UserDefaults.standard.set(Array(enabledSourceIDs), forKey: enabledSourceStorageKey)
        UserDefaults.standard.set(Array(enabledDestinationIDs), forKey: enabledDestinationStorageKey)
    }

    func emergencyStop() {
        for destination in destinations {
            if outputPorts[destination.id] == nil {
                var port = MIDIPortRef()
                MIDIOutputPortCreate(client, "MIDI Host Stop" as CFString, &port)
                outputPorts[destination.id] = port
            }
            guard let outputPort = outputPorts[destination.id] else { continue }
            var messages: [[UInt8]] = [
                [0xB0, 123, 0], // All Notes Off
                [0xB0, 120, 0], // All Sound Off
                [0xB0, 121, 0], // Reset Controllers
                [0xFC]          // MIDI Stop
            ]
            for channel in 0..<16 {
                for note in 0..<128 {
                    messages.append([0x80 | UInt8(channel), UInt8(note), 0])
                }
            }
            for message in messages {
                var list = MIDIPacketList()
                message.withUnsafeBufferPointer { buffer in
                    withUnsafeMutablePointer(to: &list) { pointer in
                        let packet = MIDIPacketListInit(pointer)
                        _ = MIDIPacketListAdd(pointer, 1024, packet, 0, message.count, buffer.baseAddress!)
                    }
                }
                MIDISend(outputPort, destination.endpoint, &list)
            }
        }
        lastMessage = "Emergency stop sent to all outputs"
    }

    func toggleRoute(source: MIDIPort, destination: MIDIPort) {
        if let existing = routes.first(where: { $0.sourceID == source.id && $0.destinationID == destination.id }) {
            disconnect(existing)
        } else {
            _ = connect(source: source, destination: destination)
        }
    }

    func isConnected(source: MIDIPort, destination: MIDIPort) -> Bool {
        routes.contains { $0.sourceID == source.id && $0.destinationID == destination.id }
    }

    private func connect(source: MIDIPort, destination: MIDIPort) -> MIDIRoute? {
        guard client != 0, destination.endpoint != 0 else { return nil }
        if outputPorts[destination.id] == nil {
            var port = MIDIPortRef()
            MIDIOutputPortCreate(client, "MIDI Host Output" as CFString, &port)
            outputPorts[destination.id] = port
        }
        let route = MIDIRoute(id: UUID(), sourceID: source.id, destinationID: destination.id, sourceChannel: nil, destinationChannel: nil)
        let context = RouteContext(session: self, routeID: route.id, outputPort: outputPorts[destination.id]!, destination: destination.endpoint, sourceChannel: nil, destinationChannel: nil)
        var inputPort = MIDIPortRef()
        guard MIDIInputPortCreate(client, "MIDI Host Route" as CFString, Self.readProc, nil, &inputPort) == noErr,
              MIDIPortConnectSource(inputPort, source.endpoint, Unmanaged.passUnretained(context).toOpaque()) == noErr else {
            if inputPort != 0 { MIDIPortDispose(inputPort) }
            return nil
        }
        routeBindings[route.id] = RouteBinding(inputPort: inputPort, context: context)
        routes.append(route)
        return route
    }

    func setRouteChannels(routeID: UUID, sourceChannel: Int?, destinationChannel: Int?) {
        guard let index = routes.firstIndex(where: { $0.id == routeID }) else { return }
        routes[index].sourceChannel = sourceChannel
        routes[index].destinationChannel = destinationChannel
        routeBindings[routeID]?.context.sourceChannel = sourceChannel
        routeBindings[routeID]?.context.destinationChannel = destinationChannel
    }

    func scheduleActivity(routeID: UUID, packetCount: Int) {
        activityLock.lock()
        guard !activityDispatchPending.contains(routeID) else {
            activityLock.unlock()
            return
        }
        activityDispatchPending.insert(routeID)
        activityLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.messageCount += packetCount
            self.lastMessage = "MIDI activity detected · \(self.messageCount) packets"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
                guard let self else { return }
                self.activityLock.lock()
                self.activityDispatchPending.remove(routeID)
                self.activityLock.unlock()
            }
        }
    }

    func updateNoteActivity(routeID: UUID, events: [(key: Int, isOn: Bool)]) {
        var notes = heldNotes[routeID, default: []]
        for event in events {
            if event.isOn { notes.insert(event.key) } else { notes.remove(event.key) }
        }
        heldNotes[routeID] = notes
        // Keep a note event visible for at least one short UI frame. This is
        // important for taps where Note On and Note Off arrive together.
        activeRoutes.insert(routeID)
        if notes.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
                guard let self, self.heldNotes[routeID]?.isEmpty != false else { return }
                self.activeRoutes.remove(routeID)
            }
        }
    }

    private func disconnect(_ route: MIDIRoute) {
        guard let source = sources.first(where: { $0.id == route.sourceID }) else { return }
        if let binding = routeBindings.removeValue(forKey: route.id) {
            MIDIPortDisconnectSource(binding.inputPort, source.endpoint)
            MIDIPortDispose(binding.inputPort)
        }
        heldNotes.removeValue(forKey: route.id)
        activeRoutes.remove(route.id)
        routes.removeAll { $0.id == route.id }
    }

    private func endpoints(for count: Int, getter: (Int) -> MIDIEndpointRef, kind: MIDIPort.PortKind) -> [MIDIPort] {
        (0..<count).compactMap { index in
            let endpoint = getter(index)
            let name = endpointName(endpoint)
            guard endpoint != 0 else { return nil }
            var uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            let stableID = uniqueID == 0 ? "\(kind.rawValue)-\(endpoint)" : "\(kind.rawValue)-\(uniqueID)"
            return MIDIPort(id: stableID, name: name, manufacturer: "CoreMIDI device", kind: kind, endpoint: endpoint)
        }
    }

    private func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var property: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &property)
        return property?.takeRetainedValue() as String? ?? "Unnamed MIDI device"
    }

    private static let readProc: MIDIReadProc = { packetList, _, refCon in
        guard let refCon else { return }
        let context = Unmanaged<RouteContext>.fromOpaque(refCon).takeUnretainedValue()
        guard let session = context.session else { return }
        let packets = packetList.pointee
        guard packets.numPackets > 0 else { return }
        let noteEvents = context.noteEvents(packetList)
        if !noteEvents.isEmpty {
            DispatchQueue.main.async {
                session.updateNoteActivity(routeID: context.routeID, events: noteEvents)
            }
        }
        context.send(packetList)
        session.scheduleActivity(routeID: context.routeID, packetCount: Int(packets.numPackets))
    }
}

private struct RouteBinding {
    let inputPort: MIDIPortRef
    let context: RouteContext
}

private final class RouteContext {
    weak var session: MIDISession?
    let routeID: UUID
    let outputPort: MIDIPortRef
    let destination: MIDIEndpointRef
    var sourceChannel: Int?
    var destinationChannel: Int?

    init(session: MIDISession, routeID: UUID, outputPort: MIDIPortRef, destination: MIDIEndpointRef, sourceChannel: Int?, destinationChannel: Int?) {
        self.session = session
        self.routeID = routeID
        self.outputPort = outputPort
        self.destination = destination
        self.sourceChannel = sourceChannel
        self.destinationChannel = destinationChannel
    }

    func send(_ packetList: UnsafePointer<MIDIPacketList>) {
        guard sourceChannel != nil || destinationChannel != nil else {
            MIDISend(outputPort, destination, packetList)
            return
        }
        let packet = packetList.pointee.packet
        let length = Int(packet.length)
        var bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(length)) }
        for byte in bytes where byte & 0xF0 >= 0x80 && byte & 0xF0 <= 0xE0 {
            if let sourceChannel, Int(byte & 0x0F) != sourceChannel - 1 { return }
        }
        if let destinationChannel {
            for index in bytes.indices {
                let status = bytes[index] & 0xF0
                if status >= 0x80 && status <= 0xE0 {
                    bytes[index] = status | UInt8(destinationChannel - 1)
                }
            }
        }
        var outputList = MIDIPacketList()
        bytes.withUnsafeBufferPointer { buffer in
            withUnsafeMutablePointer(to: &outputList) { listPointer in
                let outputPacket = MIDIPacketListInit(listPointer)
                guard let baseAddress = buffer.baseAddress else { return }
                _ = MIDIPacketListAdd(listPointer, 1024, outputPacket, packet.timeStamp, bytes.count, baseAddress)
            }
        }
        MIDISend(outputPort, destination, &outputList)
    }

    func noteEvents(_ packetList: UnsafePointer<MIDIPacketList>) -> [(key: Int, isOn: Bool)] {
        let packet = packetList.pointee.packet
        let length = Int(packet.length)
        let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(length)) }
        var events: [(key: Int, isOn: Bool)] = []
        for index in bytes.indices {
            let status = bytes[index] & 0xF0
            guard (status == 0x80 || status == 0x90), index + 2 < bytes.count else { continue }
            let channel = Int(bytes[index] & 0x0F)
            if let sourceChannel, channel != sourceChannel - 1 { continue }
            let note = Int(bytes[index + 1])
            let velocity = bytes[index + 2]
            events.append((key: channel * 128 + note, isOn: status == 0x90 && velocity > 0))
        }
        return events
    }
}

struct ContentView: View {
    @ObservedObject var session: MIDISession
    @State private var selectedSource: MIDIPort?
    @State private var selectedDestination: MIDIPort?
    @State private var portFrames: [String: CGRect] = [:]
    @State private var showPresetPanel = false
    @State private var showInputChooser = false
    @State private var showOutputChooser = false
    @State private var presetName = ""
    @State private var editingPresetID: UUID?
    @State private var editingPresetName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                portColumn(title: "MIDI INPUTS", subtitle: "Controllers and sources", ports: session.enabledSources, color: .orange, selection: $selectedSource, isInput: true)
                Spacer(minLength: 140)
                portColumn(title: "MIDI OUTPUTS", subtitle: "Select an output to edit mappings", ports: session.enabledDestinations, color: .blue, selection: $selectedDestination, showsMappings: true, isInput: false)
            }
            footer
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [AppPalette.background, AppPalette.backgroundLight]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
        .coordinateSpace(name: "midi-host-window")
        .onPreferenceChange(PortFramePreferenceKey.self) { portFrames = $0 }
        .overlay(CableOverlay(routes: session.routes, frames: portFrames, activeRoutes: session.activeRoutes))
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AppPalette.accent.opacity(0.18))
                Image(systemName: "slider.horizontal.3").foregroundColor(AppPalette.accent)
            }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("MIDI HOST").font(.system(size: 19, weight: .bold, design: .rounded)).tracking(1.5)
                Text("Hardware patchbay").font(.caption).foregroundColor(AppPalette.muted)
            }
            Spacer()
            HStack(spacing: 12) {
                statusPill(label: "\(session.routes.count) ROUTES", color: session.routes.isEmpty ? AppPalette.muted : AppPalette.green)
            }
            Button { showPresetPanel.toggle() } label: {
                Label("Presets", systemImage: "square.stack.3d.up")
            }.buttonStyle(.bordered)
                .popover(isPresented: $showPresetPanel) { presetPanel }
            Button { session.emergencyStop() } label: {
                Label("STOP", systemImage: "stop.fill")
            }.buttonStyle(.bordered).foregroundColor(.red).keyboardShortcut(.escape, modifiers: [])
            Button { session.refresh() } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func statusPill(label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(AppPalette.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(AppPalette.panel))
    }

    private var deviceSelector: some View {
        HStack(alignment: .top, spacing: 24) {
            selectionColumn(title: "INPUTS", ports: session.sources, color: .orange, all: session.enabledSourceIDs.count == session.sources.count, setAll: session.setAllSourcesEnabled, setOne: session.setSourceEnabled)
            selectionColumn(title: "OUTPUTS", ports: session.destinations, color: .blue, all: session.enabledDestinationIDs.count == session.destinations.count, setAll: session.setAllDestinationsEnabled, setOne: session.setDestinationEnabled)
        }.padding(18).frame(width: 520)
    }

    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROUTING PRESETS").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.1).foregroundColor(AppPalette.muted)
            if let currentPreset = session.presets.first(where: { $0.id == session.currentPresetID }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENT PRESET").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(AppPalette.muted)
                        Text(currentPreset.name).font(.caption.weight(.medium))
                    }
                    Spacer()
                    Button("Update") { session.updateCurrentPreset() }.buttonStyle(.bordered)
                }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(AppPalette.accent.opacity(0.10)))
            }
            HStack {
                TextField("New preset name", text: $presetName)
                Button("Save New") {
                    session.savePreset(named: presetName)
                    presetName = ""
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.routes.isEmpty)
            }
            Divider()
            if session.presets.isEmpty {
                Text("No saved presets yet.").font(.caption).foregroundColor(AppPalette.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.presets) { preset in
                            HStack {
                                if editingPresetID == preset.id {
                                    TextField("Preset name", text: $editingPresetName)
                                    Button("Save") {
                                        session.renamePreset(preset, to: editingPresetName)
                                        editingPresetID = nil
                                    }.buttonStyle(.bordered)
                                    Button("Cancel") { editingPresetID = nil }.buttonStyle(.plain).foregroundColor(AppPalette.muted)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            if session.startupPresetID == preset.id { Image(systemName: "star.fill").foregroundColor(.yellow) }
                                            Text(preset.name).font(.caption.weight(.medium))
                                        }
                                        Text("\(preset.routes.count) route\(preset.routes.count == 1 ? "" : "s")").font(.caption2).foregroundColor(AppPalette.muted)
                                    }
                                }
                                Spacer()
                                if editingPresetID != preset.id {
                                    Button("Load") {
                                        session.loadPreset(preset)
                                        showPresetPanel = false
                                    }.buttonStyle(.bordered)
                                    Button { editingPresetID = preset.id; editingPresetName = preset.name } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundColor(AppPalette.muted)
                                    Button(session.startupPresetID == preset.id ? "Startup" : "Set startup") {
                                        session.setStartupPreset(preset)
                                    }.buttonStyle(.plain).font(.caption).foregroundColor(session.startupPresetID == preset.id ? .yellow : AppPalette.muted)
                                    Button { session.deletePreset(preset) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundColor(AppPalette.muted)
                                }
                            }.padding(8).background(RoundedRectangle(cornerRadius: 7).fill(AppPalette.panel))
                        }
                    }
                }.frame(maxHeight: 220)
            }
        }.padding(18).frame(width: 330)
    }

    private func selectionColumn(title: String, ports: [MIDIPort], color: Color, all: Bool, setAll: @escaping (Bool) -> Void, setOne: @escaping (MIDIPort, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.1).foregroundColor(color)
                Spacer()
                Button(all ? "None" : "All") { setAll(!all) }.buttonStyle(.plain).font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ports) { port in
                        Toggle(isOn: Binding(get: { title == "INPUTS" ? session.enabledSourceIDs.contains(port.id) : session.enabledDestinationIDs.contains(port.id) }, set: { setOne(port, $0) })) {
                            Text(port.name).font(.caption).lineLimit(1)
                        }.toggleStyle(.checkbox)
                    }
                }
            }.frame(maxHeight: 260)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func portColumn(title: String, subtitle: String, ports: [MIDIPort], color: Color, selection: Binding<MIDIPort?>, showsMappings: Bool = false, isInput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.2).foregroundColor(color)
                Text(subtitle).font(.caption).foregroundColor(AppPalette.muted)
            }
            ScrollView(.vertical) {
                if ports.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector.horizontal").font(.title2).foregroundColor(AppPalette.muted)
                        Text("No devices found").font(.headline)
                        Text("Connect a MIDI device and refresh.").font(.caption).foregroundColor(AppPalette.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(ports) { port in
                            PortCard(port: port, color: color, isSelected: selection.wrappedValue == port)
                                .onTapGesture { selection.wrappedValue = port }
                                .modifier(DragSourceModifier(port: port))
                                .popover(isPresented: Binding(
                                    get: { showsMappings && selection.wrappedValue == port },
                                    set: { isPresented in
                                        if !isPresented && selection.wrappedValue == port { selection.wrappedValue = nil }
                                    }
                                )) {
                                    if showsMappings { outputMappings(for: port) }
                                }
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: PortFramePreferenceKey.self, value: [port.id: geometry.frame(in: .named("midi-host-window"))])
                                })
                                .onDrop(of: port.kind == .destination ? [.text] : [], isTargeted: nil) { providers, _ in
                                    guard port.kind == .destination else { return false }
                                    return handleDrop(providers, on: port)
                                }
                        }
                    }
                }
                addDeviceButton(isInput: isInput)
            }
            .frame(maxHeight: .infinity)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func addDeviceButton(isInput: Bool) -> some View {
        Button {
            if isInput { showInputChooser = true } else { showOutputChooser = true }
        } label: {
            Label(isInput ? "Select input" : "Select output", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(isInput ? .orange : .blue)
        .popover(isPresented: Binding(
            get: { isInput ? showInputChooser : showOutputChooser },
            set: { isPresented in
                if isInput { showInputChooser = isPresented } else { showOutputChooser = isPresented }
            }
        )) {
            if isInput {
                selectionColumn(title: "INPUTS", ports: session.sources, color: .orange, all: session.enabledSourceIDs.count == session.sources.count, setAll: session.setAllSourcesEnabled, setOne: session.setSourceEnabled)
                    .padding(18).frame(width: 280)
            } else {
                selectionColumn(title: "OUTPUTS", ports: session.destinations, color: .blue, all: session.enabledDestinationIDs.count == session.destinations.count, setAll: session.setAllDestinationsEnabled, setOne: session.setDestinationEnabled)
                    .padding(18).frame(width: 280)
            }
        }
    }

    private func outputMappings(for output: MIDIPort) -> some View {
        let mappings = session.routes.filter { $0.destinationID == output.id }
        return VStack(alignment: .leading, spacing: 8) {
            Text("MAPPINGS TO THIS OUTPUT")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundColor(AppPalette.muted)
                .frame(maxWidth: .infinity, alignment: .center)
            if mappings.isEmpty {
                Text("No inputs mapped").font(.caption).foregroundColor(AppPalette.muted)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(mappings) { route in
                            mappingRow(route)
                        }
                    }
                }.frame(maxHeight: 210)
            }
        }
        .padding(.top, 10)
    }

    private func mappingRow(_ route: MIDIRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text(session.sources.first(where: { $0.id == route.sourceID })?.name ?? "Input").font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Button {
                    guard let source = session.sources.first(where: { $0.id == route.sourceID }),
                          let destination = session.destinations.first(where: { $0.id == route.destinationID }) else { return }
                    session.toggleRoute(source: source, destination: destination)
                } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.plain).foregroundColor(.red.opacity(0.8))
            }
            HStack(spacing: 5) {
                Text("In").font(.caption2).foregroundColor(AppPalette.muted)
                Picker("Input", selection: Binding(get: { route.sourceChannel }, set: { session.setRouteChannels(routeID: route.id, sourceChannel: $0, destinationChannel: route.destinationChannel) })) {
                    Text("All").tag(nil as Int?)
                    ForEach(1...16, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }.labelsHidden().frame(width: 52)
                Text("Out").font(.caption2).foregroundColor(AppPalette.muted)
                Picker("Output", selection: Binding(get: { route.destinationChannel }, set: { session.setRouteChannels(routeID: route.id, sourceChannel: route.sourceChannel, destinationChannel: $0) })) {
                    Text("Same").tag(nil as Int?)
                    ForEach(1...16, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }.labelsHidden().frame(width: 58)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppPalette.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.border, lineWidth: 1))
    }

    private func handleDrop(_ providers: [NSItemProvider], on destination: MIDIPort) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let identifier = object as? String else { return }
            DispatchQueue.main.async {
                guard let source = session.sources.first(where: { $0.id == identifier }) else { return }
                selectedSource = source
                selectedDestination = destination
                if !session.isConnected(source: source, destination: destination) {
                    session.toggleRoute(source: source, destination: destination)
                }
            }
        }
        return true
    }

    private var patchbay: some View {
        ZStack {
            PatchbayGrid()
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PATCHBAY").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.2)
                        Text("Signal routing surface").font(.caption).foregroundColor(AppPalette.muted)
                    }
                    Spacer()
                    Circle().fill(session.routes.isEmpty ? AppPalette.muted : AppPalette.green).frame(width: 7, height: 7)
                    Text(session.routes.isEmpty ? "IDLE" : "LIVE").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(AppPalette.muted)
                }
                HStack(spacing: 12) {
                    Button { if let source = selectedSource, let destination = selectedDestination { session.toggleRoute(source: source, destination: destination) } } label: {
                        Label("Patch selected", systemImage: "plus").font(.caption.weight(.semibold))
                    }.buttonStyle(.bordered).disabled(selectedSource == nil || selectedDestination == nil)
                    Spacer()
                }
                if session.routes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundColor(AppPalette.accent.opacity(0.7))
                        Text("No signal paths").font(.headline)
                        Text("Select an input and output to create a cable.").font(.caption).foregroundColor(AppPalette.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 45)
                } else {
                    /*
                    VStack(alignment: .leading, spacing: 9) {
                        Text("ACTIVE SIGNAL PATHS").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.1).foregroundColor(AppPalette.muted)
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 10) {
                                ForEach(session.routes) { route in
                                    let sourceName = session.sources.first(where: { $0.id == route.sourceID })?.name ?? "Input"
                                    let destinationName = session.destinations.first(where: { $0.id == route.destinationID })?.name ?? "Output"
                                    VStack(alignment: .leading, spacing: 9) {
                                        HStack(spacing: 8) {
                                            Text(sourceName).lineLimit(1).font(.caption.weight(.medium))
                                            CableLine(color: .orange).frame(height: 18)
                                            Text(destinationName).lineLimit(1).font(.caption.weight(.medium))
                                            Button {
                                                guard let source = session.sources.first(where: { $0.id == route.sourceID }), let destination = session.destinations.first(where: { $0.id == route.destinationID }) else { return }
                                                session.toggleRoute(source: source, destination: destination)
                                            } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(AppPalette.muted)
                                        }
                                    HStack(spacing: 8) {
                                        Text("Input channel").foregroundColor(.secondary)
                                        Picker("Input channel", selection: Binding(
                                            get: { route.sourceChannel },
                                            set: { session.setRouteChannels(routeID: route.id, sourceChannel: $0, destinationChannel: route.destinationChannel) }
                                        )) {
                                            Text("All").tag(nil as Int?)
                                            ForEach(1...16, id: \.self) { channel in
                                                Text(String(channel)).tag(Optional(channel))
                                            }
                                        }.labelsHidden().frame(width: 55)
                                        Text("Output channel").foregroundColor(.secondary)
                                        Picker("Output channel", selection: Binding(
                                            get: { route.destinationChannel },
                                            set: { session.setRouteChannels(routeID: route.id, sourceChannel: route.sourceChannel, destinationChannel: $0) }
                                        )) {
                                            Text("Same").tag(nil as Int?)
                                            ForEach(1...16, id: \.self) { channel in
                                                Text(String(channel)).tag(Optional(channel))
                                            }
                                        }.labelsHidden().frame(width: 60)
                                    }.font(.caption)
                                }
                                        .padding(12)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(AppPalette.panel))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppPalette.border, lineWidth: 1))
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 250)
                        .opacity(0)
                        .frame(height: 0)
                    }
                    .opacity(0)
                    .frame(height: 0)
                    */
                    EmptyView()
                }
                Spacer()
            }.padding(20)
        }
        .frame(width: 360)
        .background(AppPalette.canvas.opacity(0.72))
        .overlay(Rectangle().fill(AppPalette.border).frame(width: 1), alignment: .leading)
        .overlay(Rectangle().fill(AppPalette.border).frame(width: 1), alignment: .trailing)
    }

    private var footer: some View {
        HStack {
            Circle().fill(session.messageCount > 0 ? .green : .secondary).frame(width: 8, height: 8)
            Text(session.lastMessage).font(.caption).foregroundColor(AppPalette.muted)
            Spacer()
            Text("\(session.sources.count) inputs  ·  \(session.destinations.count) outputs  ·  \(session.routes.count) routes").font(.caption).foregroundColor(AppPalette.muted)
        }.padding(.horizontal, 24).padding(.vertical, 13)
            .background(AppPalette.panel.opacity(0.7))
    }
}

struct PortCard: View {
    let port: MIDIPort
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: port.kind == .source ? "keyboard" : "waveform")
                .foregroundColor(color).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(port.name).font(.body.weight(.medium)).lineLimit(1)
            }
            Spacer()
            Circle().stroke(isSelected ? color : Color.secondary.opacity(0.35), lineWidth: isSelected ? 3 : 1).frame(width: 13, height: 13)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? color.opacity(0.16) : AppPalette.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? color : AppPalette.border, lineWidth: isSelected ? 1.5 : 1))
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.10), radius: 8, y: 3)
        .contentShape(Rectangle())
    }
}

private enum AppPalette {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.085)
    static let backgroundLight = Color(red: 0.085, green: 0.095, blue: 0.12)
    static let canvas = Color(red: 0.035, green: 0.042, blue: 0.058)
    static let panel = Color(red: 0.105, green: 0.12, blue: 0.15)
    static let border = Color.white.opacity(0.10)
    static let muted = Color.white.opacity(0.56)
    static let accent = Color(red: 0.45, green: 0.70, blue: 1.0)
    static let green = Color(red: 0.35, green: 0.86, blue: 0.62)
}

private struct PatchbayGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let spacing: CGFloat = 22
                stride(from: 0, through: geometry.size.width, by: spacing).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
                stride(from: 0, through: geometry.size.height, by: spacing).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(AppPalette.border.opacity(0.22), lineWidth: 0.5)
        }
    }
}

private struct CableLine: Shape {
    let color: Color

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control1: CGPoint(x: rect.width * 0.35, y: 0), control2: CGPoint(x: rect.width * 0.65, y: rect.height))
        return path
    }

    var body: some View { self.stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round)) }
}

private struct DragSourceModifier: ViewModifier {
    let port: MIDIPort

    func body(content: Content) -> some View {
        if port.kind == .source {
            content.onDrag { NSItemProvider(object: port.id as NSString) }
        } else {
            content
        }
    }
}

private struct PortFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct CableOverlay: View {
    let routes: [MIDIRoute]
    let frames: [String: CGRect]
    let activeRoutes: Set<UUID>

    var body: some View {
        GeometryReader { _ in
            ZStack {
                ForEach(routes) { route in
                    if let source = frames[route.sourceID], let destination = frames[route.destinationID] {
                        let active = activeRoutes.contains(route.id)
                        CablePath(source: source, destination: destination)
                            .stroke(AppPalette.accent.opacity(0.68), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .allowsHitTesting(false)
                        EndpointIndicator(point: CGPoint(x: source.maxX, y: source.midY), active: active)
                        EndpointIndicator(point: CGPoint(x: destination.minX, y: destination.midY), active: active)
                    }
                }
            }
        }
    }
}

private struct RouteBadge: View {
    let route: MIDIRoute
    @ObservedObject var session: MIDISession
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(session.activeRoutes.contains(route.id) ? AppPalette.green : AppPalette.accent).frame(width: 5, height: 5)
                Text(channelSummary).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(AppPalette.panel))
            .overlay(Capsule().stroke(AppPalette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            RouteEditor(route: route, session: session, isPresented: $isPresented)
        }
    }

    private var channelSummary: String {
        let input = route.sourceChannel.map(String.init) ?? "All"
        let output = route.destinationChannel.map(String.init) ?? "Same"
        return "In \(input) → Out \(output)"
    }
}

private struct RouteEditor: View {
    let route: MIDIRoute
    @ObservedObject var session: MIDISession
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROUTE SETTINGS").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.1).foregroundColor(AppPalette.muted)
            Text("Input → Output").font(.headline)
            HStack {
                Text("Input channel").foregroundColor(AppPalette.muted)
                Picker("Input channel", selection: Binding(get: { route.sourceChannel }, set: { session.setRouteChannels(routeID: route.id, sourceChannel: $0, destinationChannel: route.destinationChannel) })) {
                    Text("All").tag(nil as Int?)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0 as Int?) }
                }.labelsHidden()
            }
            HStack {
                Text("Output channel").foregroundColor(AppPalette.muted)
                Picker("Output channel", selection: Binding(get: { route.destinationChannel }, set: { session.setRouteChannels(routeID: route.id, sourceChannel: route.sourceChannel, destinationChannel: $0) })) {
                    Text("Same").tag(nil as Int?)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0 as Int?) }
                }.labelsHidden()
            }
            Button("Remove route") {
                guard let source = session.sources.first(where: { $0.id == route.sourceID }), let destination = session.destinations.first(where: { $0.id == route.destinationID }) else { return }
                session.toggleRoute(source: source, destination: destination)
                isPresented = false
            }.foregroundColor(.red)
        }.padding(18).frame(width: 240)
    }
}

private struct EndpointIndicator: View {
    let point: CGPoint
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? AppPalette.green : AppPalette.accent.opacity(0.55))
            .frame(width: active ? 12 : 8, height: active ? 12 : 8)
            .shadow(color: active ? AppPalette.green.opacity(0.9) : .clear, radius: active ? 7 : 0)
            .position(point)
    }
}

private struct CablePath: Shape {
    let source: CGRect
    let destination: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: source.maxX, y: source.midY)
        let end = CGPoint(x: destination.minX, y: destination.midY)
        let bend = max(50, abs(end.x - start.x) * 0.42)
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return path
    }
}

private struct SignalPulse: View {
    let source: CGRect
    let destination: CGRect
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { _ in
            Circle()
                .fill(AppPalette.green)
                .frame(width: 8, height: 8)
                .shadow(color: AppPalette.green, radius: 6)
                .position(point(at: progress))
        }
        .onAppear {
            withAnimation(.linear(duration: 0.10)) { progress = 1 }
        }
    }

    private func point(at t: CGFloat) -> CGPoint {
        let start = CGPoint(x: source.maxX, y: source.midY)
        let end = CGPoint(x: destination.minX, y: destination.midY)
        let bend = max(50, abs(end.x - start.x) * 0.42)
        let first = CGPoint(x: start.x + bend, y: start.y)
        let second = CGPoint(x: end.x - bend, y: end.y)
        let oneMinusT = 1 - t
        let x = oneMinusT * oneMinusT * oneMinusT * start.x + 3 * oneMinusT * oneMinusT * t * first.x + 3 * oneMinusT * t * t * second.x + t * t * t * end.x
        let y = oneMinusT * oneMinusT * oneMinusT * start.y + 3 * oneMinusT * oneMinusT * t * first.y + 3 * oneMinusT * t * t * second.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }
}
