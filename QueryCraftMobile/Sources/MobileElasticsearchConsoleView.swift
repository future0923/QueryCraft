import SwiftUI
import UIKit
import QueryCraftMobileCore

struct MobileElasticsearchConsoleView: View {
    @Bindable var console: MobileElasticsearchConsole
    @State private var showPreview = false
    @State private var history = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("执行范围", selection: $console.scope) { Text("当前 / 选区").tag("current"); Text("整篇文稿").tag("all") }.pickerStyle(.segmented)
                Menu {
                    Button("格式化") { console.format() }
                    Button("历史") { history = true }
                    Toggle("安全锁", isOn: Binding(get: { console.owner.safetyLock.isEnabled }, set: { $0 ? console.owner.safetyLock.enable() : console.owner.safetyLock.disable() }))
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                Button { Task { [owner = console.owner] in defer { _ = owner }; await console.prepare()?.value; if console.preview != nil { showPreview = true } } } label: { Label("运行", systemImage: "play.fill") }.disabled(!console.canRun)
            }.padding(.horizontal, 12).frame(height: 48)
            MobileElasticsearchEditor(console: console).frame(minHeight: 130, idealHeight: 220, maxHeight: 270).accessibilityIdentifier("elasticsearchRESTEditor")
            ScrollView(.horizontal) {
                HStack(spacing: 8) { ForEach(console.completions) { item in Button(item.label) { console.accept(item) }.buttonStyle(.bordered).font(.caption.monospaced()) } }.padding(.horizontal, 12)
            }.frame(height: 44).background(Color(uiColor: .secondarySystemBackground))
            Divider()
            HStack {
                if console.results.count > 1 {
                    Menu {
                        Picker("结果", selection: $console.selectedResult) {
                            ForEach(Array(console.results.enumerated()), id: \.element.id) { index, result in Text("\(index + 1) · HTTP \(result.response.statusCode)").tag(index) }
                        }
                    } label: { Text("\(console.selectedResult + 1)/\(console.results.count)").font(.caption.monospacedDigit()) }
                }
                if let result = console.currentResult {
                    Text(result.request.method.rawValue + " " + result.request.path).font(.caption.monospaced()).lineLimit(1)
                    Spacer(minLength: 4)
                    Toggle("JSON", isOn: $console.showsJSON).toggleStyle(.button).font(.caption)
                    ShareLink(item: result.details.fullResponse) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享完整响应")
                } else { Text("响应").font(.caption).foregroundStyle(.secondary); Spacer() }
            }.padding(.horizontal, 12).frame(height: 40)
            if let result = console.currentResult {
                if !result.details.diagnostics.isEmpty || result.details.acceptedTask != nil {
                    DisclosureGroup("响应诊断与任务") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(result.details.diagnostics, id: \.self) { diagnostic in
                                    HStack(alignment: .top) {
                                        Text(diagnostic.message).font(.caption).textSelection(.enabled)
                                        if console.canLocate(diagnostic) { Button("定位错误") { console.locate(diagnostic) }.font(.caption) }
                                    }
                                }
                                if let task = result.details.acceptedTask { Button("查看后台任务 " + task) { console.openTask(task) } }
                            }
                        }.frame(maxHeight: 160)
                    }.padding(.horizontal, 12)
                }
                if !console.showsJSON, !result.details.prefersJSON, case .grid(let page) = result.output {
                    MobileResultsView(data: .init(esColumns: page.columns, rows: page.rows), revision: result.id.uuidString, widthKey: console.owner.profile.id.uuidString + "es-console", hasLoaded: true, isLoading: console.isRunning, errorMessage: console.message, status: "HTTP \(result.response.statusCode) · " + result.details.summary(copy: .current), exportName: "es-console", exportDialect: nil)
                } else {
                    ScrollView { MobileElasticsearchText(text: result.details.fullResponse).padding(12) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    status
                }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay { if !console.isRunning { Text("运行请求后在此查看结果").foregroundStyle(.secondary) } }
                status
            }
            if console.needsVerification {
                HStack {
                    Button("运行编辑器中的只读核实请求") { console.verifyCurrentRead() }.disabled(console.isRunning)
                    Button("只读核实") { console.verify() }.disabled(console.isRunning)
                    Button("已核对影响，结束本次操作") { console.finishVerification() }.disabled(!console.verified || console.isRunning)
                }.font(.caption).padding(8)
            }
        }
        .onChange(of: console.preview) { _, preview in if preview != nil { showPreview = true } }
        .sheet(isPresented: $showPreview) {
            NavigationStack {
                Form {
                    Section("目标连接") {
                        LabeledContent("连接", value: console.owner.profile.name)
                        LabeledContent("服务器", value: console.owner.profile.host + ":" + String(console.owner.profile.port))
                    }
                    Section("完整请求") { MobileElasticsearchText(text: console.preview ?? "请求已失效，请重新预览。") }
                    Section {
                        Toggle("安全锁", isOn: Binding(get: { console.owner.safetyLock.isEnabled }, set: { $0 ? console.owner.safetyLock.enable() : console.owner.safetyLock.disable() }))
                        Text("写入可能立即生效；批次不是事务，失败时停止后续请求。请核对目标、路径和完整请求体。")
                        Button("确认执行") { console.run(); showPreview = false }.disabled(console.preview == nil || !console.canRun)
                    }
                }.navigationTitle("确认 REST 请求").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showPreview = false; console.invalidate() } } }
            }
        }
        .sheet(isPresented: $history) {
            NavigationStack {
                List(console.history, id: \.self) { text in Button { console.source = text; history = false } label: { Text(text).font(.caption.monospaced()).lineLimit(4) } }
                    .navigationTitle("请求历史").toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { history = false } } }
            }
        }
    }
    private var status: some View {
        HStack { ProgressView().controlSize(.small).opacity(console.isRunning || console.isPreparing ? 1 : 0); Text(console.message ?? (console.isRunning ? "正在等待服务器…" : "结果完整响应可分享；表格最多显示 1,000 行")).font(.caption).lineLimit(2).foregroundStyle(console.message == nil ? Color.secondary : .red); Spacer(minLength: 0) }.padding(.horizontal, 12).frame(height: 48)
    }
}

struct MobileElasticsearchEditor: UIViewRepresentable {
    @Bindable var console: MobileElasticsearchConsole
    func makeCoordinator() -> Coordinator { Coordinator(console) }
    func makeUIView(context: Context) -> UITextView {
        let view = RESTTextView(); view.console = console; view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular); view.backgroundColor = .systemBackground
        view.textColor = .label; view.autocapitalizationType = .none; view.autocorrectionType = .no; view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.textContainerInset = .init(top: 10, left: 12, bottom: 10, right: 12); view.keyboardDismissMode = .interactive
        view.text = console.source; context.coordinator.highlight(view); return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard view.markedTextRange == nil else { return }
        context.coordinator.isApplying = true
        defer { context.coordinator.isApplying = false }
        if view.text != console.source { view.text = console.source; context.coordinator.highlight(view) }
        let range = console.selection
        if range.location >= 0, NSMaxRange(range) <= view.text.utf16.count, view.selectedRange != range { view.selectedRange = range; view.scrollRangeToVisible(range) }
        view.isEditable = !console.isRunning
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        let console: MobileElasticsearchConsole
        var isApplying = false
        init(_ console: MobileElasticsearchConsole) { self.console = console }
        func textViewDidChange(_ view: UITextView) {
            guard !isApplying else { return }
            console.markedText = view.markedTextRange != nil
            console.source = view.text; console.selection = view.selectedRange
            if view.markedTextRange == nil { highlight(view) }
        }
        func highlight(_ view: UITextView) {
            guard view.markedTextRange == nil, view.text.utf8.count <= 262_144 else { return }
            let text = view.text ?? "", full = NSRange(location: 0, length: text.utf16.count)
            view.textStorage.beginEditing()
            view.textStorage.addAttributes([.foregroundColor: UIColor.label, .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)], range: full)
            // Request boundaries use the same parser as execution. Color is a UIKit presentation concern.
            if let requests = try? ElasticsearchConsoleParser().parse(text) {
                for request in requests {
                    let line = (text as NSString).lineRange(for: NSRange(location: request.sourceRange.location, length: 0))
                    if NSMaxRange(line) <= full.length { view.textStorage.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: line) }
                }
            }
            if let expression = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#) {
                for match in expression.matches(in: text, range: full) { view.textStorage.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: match.range) }
            }
            view.textStorage.endEditing()
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isApplying else { return }
            console.markedText = view.markedTextRange != nil
            console.selection = view.selectedRange
        }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            (view.text.utf8.count + text.utf8.count <= 1_048_576) || text.isEmpty
        }
    }
    @MainActor final class RESTTextView: UITextView {
        weak var console: MobileElasticsearchConsole?
        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(complete)), UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(run)), UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(complete)), UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeKeyboard))]
        }
        @objc private func complete() { if let item = console?.completions.first { console?.accept(item) } else { console?.scheduleCompletion() } }
        @objc private func run() {
            guard let console else { return }
            Task { [owner = console.owner] in defer { _ = owner }; await console.prepare()?.value }
        }
        @objc private func closeKeyboard() { resignFirstResponder() }
    }
}
