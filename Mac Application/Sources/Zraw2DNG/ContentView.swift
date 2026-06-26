import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @State private var showingHelp = false
    @State private var isTargeted = false
    @State private var selectedIndices: Set<Int> = []
    @State private var lastClickedIndex: Int? = nil
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.red.opacity(0.6))
            controlsRow
            Divider().background(Color.red.opacity(0.6))
            fileList
            Divider().background(Color.red.opacity(0.6))
            optionsPanel
            Divider().background(Color.red.opacity(0.6))
            progressArea
            if vm.showLog {
                logPanel
            }
            Divider().background(Color.red.opacity(0.6))
            footer
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 520)
        .background(Color(white: 0.12))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Zraw2DNG").font(.title2).bold().foregroundColor(.white)
            Spacer()
            Button("Help") { showingHelp.toggle() }
                .popover(isPresented: $showingHelp) { helpContent }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Controls Row

    private var controlsRow: some View {
        HStack {
            Button("Import Files…") { vm.addFiles() }
            Button("Clear All") { vm.clearAll() }
                .disabled(vm.queue.isEmpty)
            if !selectedIndices.isEmpty {
                Button("Reset") {
                    Task {
                        for idx in selectedIndices.sorted().reversed() {
                            await vm.resetItem(at: idx)
                        }
                        selectedIndices.removeAll()
                    }
                }
                .disabled(!selectedIndices.contains(where: { idx in
                    idx < vm.queue.count && vm.queue[idx].status.isTerminal
                }))
                Button("Remove", role: .destructive) {
                    vm.removeItems(at: IndexSet(selectedIndices))
                    selectedIndices.removeAll()
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Text("Output:").font(.caption).foregroundColor(.white.opacity(0.7))
                TextField("Same as source", text: $vm.outputPathText)
                    .textFieldStyle(.roundedBorder).font(.caption).frame(maxWidth: 200)
                    .onSubmit { vm.confirmOutputPath() }
                Button("Browse…") { vm.chooseOutputDir() }
                    .buttonStyle(.bordered).controlSize(.small)
                if vm.options.outputDir != nil {
                    Button("Clear") {
                        vm.options.outputDir = nil
                        vm.outputPathText = ""
                    }.buttonStyle(.borderless).foregroundColor(.red).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(Array(vm.queue.enumerated()), id: \.element.id) { i, item in
                QueueRowView(item: item, isSelected: selectedIndices.contains(i))
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color(white: 0.08))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if case .processing = item.status { return }
                        guard let event = NSApp.currentEvent else {
                            selectedIndices = [i]; lastClickedIndex = i; return
                        }
                        if event.modifierFlags.contains(.shift), let last = lastClickedIndex {
                            let range = min(last, i)...max(last, i)
                            selectedIndices.formUnion(range)
                        } else if event.modifierFlags.contains(.command) {
                            selectedIndices.formSymmetricDifference([i])
                            lastClickedIndex = i
                        } else {
                            selectedIndices = [i]
                            lastClickedIndex = i
                        }
                    }
                    .contextMenu {
                        if item.status.isTerminal {
                            Button("Reset") {
                                Task {
                                    for idx in selectedIndices.sorted() {
                                        await vm.resetItem(at: idx)
                                    }
                                    selectedIndices.removeAll()
                                }
                            }
                        }
                        let activeIndex = vm.queue.indices.first { if case .processing = vm.queue[$0].status { return true }; return false }
                        if selectedIndices.allSatisfy({ $0 != activeIndex }) || activeIndex == nil {
                            Button("Remove", role: .destructive) {
                                let toRemove = selectedIndices.isEmpty ? [i] : selectedIndices
                                vm.removeItems(at: IndexSet(toRemove))
                                selectedIndices.removeAll()
                            }
                        }
                    }
            }
            .onDelete { offsets in vm.removeItems(at: offsets) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.12))
        .overlay {
            if vm.queue.isEmpty {
                Text("Drop MOV/ZRAW files here")
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 200)
    }

    // MARK: - Options Panel

    private var optionsPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                Text("Compression:").font(.caption).foregroundColor(.white.opacity(0.7))
                Picker("", selection: $vm.options.compression) {
                    ForEach(CompressionOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().frame(width: 130)


                Text("Model:").font(.caption).foregroundColor(.white.opacity(0.7))
                Picker("", selection: Binding(
                    get: { vm.options.cameraModelOverride },
                    set: { vm.selectCameraModel($0) }
                )) {
                    ForEach(CameraModelOverride.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().frame(maxWidth: 200)

                Spacer()
            }

            HStack(spacing: 16) {
                Text("Baseline Exposure:").font(.caption).foregroundColor(.white.opacity(0.7))
                Picker("", selection: Binding(
                    get: { vm.options.baselineExposure },
                    set: { vm.setBaselineExposure($0) }
                )) {
                    ForEach(Array(stride(from: -6.0, through: 6.0, by: 0.5)), id: \.self) { val in
                        Text(String(format: "%+.1f", val)).tag(val)
                    }
                }
                .labelsHidden().frame(width: 80)

                Text("Concurrent frames:").font(.caption).foregroundColor(.white.opacity(0.7))
                Picker("", selection: $vm.options.maxConcurrentFrames) {
                    ForEach(Array(stride(from: 1, through: max(1, ProcessInfo.processInfo.processorCount), by: 1)), id: \.self) { val in
                        Text("\(val)").tag(val)
                    }
                }
                .labelsHidden().frame(width: 60)
                Text("(\(ProcessInfo.processInfo.processorCount) cores)").font(.caption2).foregroundColor(.white.opacity(0.4))

                Spacer()

                Text("\(vm.queue.count) file(s)").font(.caption).foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Progress Area

    private var progressArea: some View {
        VStack(spacing: 6) {
            if vm.isProcessing {
                ProgressView(value: vm.overallProgressValue)
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .animation(.default, value: vm.overallProgressValue)
            }

            HStack(spacing: 12) {
                if vm.isProcessing {
                    Button("Cancel", role: .destructive) { vm.cancelConversion() }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("Start Convert") { vm.startConversion() }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(!vm.canConvert)
                }

                Spacer()

                Text(vm.statusMessage)
                    .font(.caption).foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Created by Derek Morrison - Based on Zraw-Parser by Storyboard Creativity")
                .font(.caption2).foregroundColor(.white.opacity(0.35))
            Spacer()
            if !vm.queue.isEmpty {
                Text(vm.queueProgressText)
                    .font(.caption).foregroundColor(.white.opacity(0.5))
                    .padding(.trailing, 8)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.showLog.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: vm.showLog ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                    Text("Log")
                        .font(.caption2)
                }
                .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 4)
    }

    // MARK: - Log Panel

    private var logPanel: some View {
        VStack(spacing: 0) {
            Divider().background(Color.red.opacity(0.6))
            HStack {
                Text("Console").font(.caption).foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Copy All") {
                    let text = vm.logMessages.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button("Clear") { vm.logMessages.removeAll() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(white: 0.1))
            Divider().background(Color.red.opacity(0.6))
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logMessages.enumerated()), id: \.offset) { _, msg in
                            Text(msg)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(nil)
                                .textSelection(.enabled)
                        }
                        Color.clear.id("logBottom")
                    }
                    .padding(6)
                }
                .background(Color(white: 0.08))
                .frame(height: 160)
                .onChange(of: vm.logMessages.count) {
                    withAnimation {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Help

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zraw2DNG").bold()
            Text("1. Import ZRAW .mov/.zraw files (or drag-drop)")
            Text("2. Set output options")
            Text("3. Click Start Convert")
            Text("")
            Text("Per-file parallel frame decoding")
            Text("Audio extracted as WAV alongside DNG sequence")
        }
        .padding().frame(width: 240)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = await loadURL(from: p) { urls.append(url) }
            }
            await MainActor.run { vm.addURLs(urls) }
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Queue Row

struct QueueRowView: View {
    let item: QueueItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.zcamInfo?.clipName ?? item.url.lastPathComponent)
                        .font(.body).fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let info = item.movieInfo {
                        HStack(spacing: 12) {
                            Text("\(info.videoWidth)×\(info.videoHeight)").foregroundColor(.white.opacity(0.6))
                            Text(String(format: "%.2f fps", info.framerate)).foregroundColor(.white.opacity(0.6))
                            Text("\(info.frameCount) frames").foregroundColor(.white.opacity(0.6))
                            if info.hasAudio {
                                Text("Audio: \(info.audioSampleRate/1000, specifier: "%.0f")kHz \(info.audioSampleSize)bit")
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .font(.caption)

                        HStack(spacing: 12) {
                            Text("TC: \(info.timecodeString)")
                            Text("Model: \(info.cameraModel)")
                            if let zcam = item.zcamInfo {
                                Text("Reel: \(zcam.reelName)")
                            }
                        }
                        .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                }

                Spacer()

                if case .processing(let n, let total) = item.status {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: Double(n), total: Double(total))
                            .progressViewStyle(.linear)
                            .tint(.red)
                            .frame(width: 100)
                        Text("\(n)/\(total)")
                            .font(.caption2).foregroundColor(.white.opacity(0.6))
                    }
                } else {
                    statusBadge
                }
            }
        }
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.red : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending: Image(systemName: "circle").foregroundColor(.gray)
        case .loading: ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        case .ready: Image(systemName: "checkmark.circle").foregroundColor(.green)
        case .processing: Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.red)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "xmark.circle").foregroundColor(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundColor(.orange)
        case .warning: Image(systemName: "exclamationmark.triangle").foregroundColor(.yellow)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .failed(let e):
            Text("Failed").font(.caption).foregroundColor(.red).help(e)
        case .completed:
            Text("Done").font(.caption).foregroundColor(.green)
        case .warning(let msg):
            Text("Warning").font(.caption).foregroundColor(.yellow).help(msg)
        default:
            Text(item.status.label).font(.caption).foregroundColor(.white.opacity(0.6))
        }
    }
}
