//
//  PDFReadingAssistantView.swift
//  Zotero
//

import SwiftUI
import UIKit

@MainActor
final class PDFReadingAssistantModel: ObservableObject {
    @Published var messages: [PDFReadingAssistantMessage]
    @Published var draft = ""
    @Published var scope: PDFReadingAssistantScope = .document
    @Published var isBusy = false
    @Published var status = ""
    @Published var error: String?
    let history: PDFReadingAssistantHistory
    var contextProvider: ((PDFReadingAssistantScope, String) async throws -> PDFReadingAssistantContext)?
    var onPage: ((Int) -> Void)?
    var onClose: (() -> Void)?
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    init(documentID: String) {
        history = PDFReadingAssistantHistory(documentID: documentID)
        messages = history.load()
    }

    deinit { task?.cancel() }

    func send(_ preset: String? = nil, scope requestedScope: PDFReadingAssistantScope? = nil) {
        guard !isBusy else { return }
        let question = (preset ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard question.count <= 6000 else { error = "问题过长，请控制在 6000 字以内。"; return }
        let configuration = PDFReadingAssistantConfiguration.saved
        do { _ = try configuration.validatedURL() } catch { self.error = error.localizedDescription; return }
        guard let contextProvider else { return }
        let chosenScope = requestedScope ?? scope
        scope = chosenScope
        let id = UUID()
        requestID = id
        error = nil
        isBusy = true
        status = "正在读取\(chosenScope.rawValue)…"
        let previous = messages
        task = Task { [weak self] in
            guard let self else { return }
            var answerID: UUID?
            do {
                let context = try await contextProvider(chosenScope, question)
                try Task.checkCancellation()
                guard requestID == id else { return }
                status = context.description
                messages.append(PDFReadingAssistantMessage(role: "user", content: question, contextDescription: context.description))
                let answer = PDFReadingAssistantMessage(role: "assistant", content: "", status: .streaming)
                answerID = answer.id
                messages.append(answer)
                draft = ""
                let payload = PDFReadingAssistantService.messages(context: context.text, history: previous, question: question)
                try await PDFReadingAssistantService.stream(configuration: configuration, messages: payload) { [weak self] text in
                    await self?.receive(text, messageID: answer.id, requestID: id)
                }
                guard requestID == id else { return }
                setStatus(.complete, for: answer.id)
            } catch {
                guard requestID == id else { return }
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if let answerID { setStatus(cancelled ? .stopped : .failed, for: answerID) }
                if !cancelled {
                    self.error = error is URLError ? "网络连接失败或超时，请检查网络与 API 地址后重试。" : error.localizedDescription
                }
            }
            guard requestID == id else { return }
            isBusy = false
            task = nil
            persist()
        }
    }

    private func receive(_ text: String, messageID: UUID, requestID: UUID) {
        guard self.requestID == requestID, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].content = text
    }

    private func setStatus(_ status: PDFReadingAssistantMessage.Status, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = status
    }

    func stop() {
        task?.cancel()
        task = nil
        requestID = nil
        isBusy = false
        for index in messages.indices where messages[index].status == .streaming { messages[index].status = .stopped }
        persist()
    }

    func clear() {
        stop()
        do {
            try history.clear()
            messages = []
            status = ""
            error = nil
        } catch { self.error = "聊天记录未能清除，请重试。" }
    }

    private func persist() {
        if messages.count > 120 { messages = Array(messages.suffix(120)) }
        do { try history.save(messages) } catch { self.error = "未能保存本地聊天记录，请复制需要保留的内容。" }
    }
}

struct PDFReadingAssistantView: View {
    @ObservedObject var model: PDFReadingAssistantModel
    @State private var showSettings = false
    @State private var confirmClear = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .sheet(isPresented: $showSettings) { PDFReadingAssistantSettingsView() }
        .confirmationDialog("清除此文献在本机的聊天记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除聊天", role: .destructive) { model.clear() }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "zotero-ai-page" else { return url.scheme == "https" ? .systemAction : .discarded }
            guard let host = url.host, let page = Int(host), page > 0 else { return .discarded }
            model.onPage?(page)
            return .handled
        })
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("AI 阅读助手").font(.headline)
            Spacer(minLength: 0)
            Menu {
                Button { showSettings = true } label: { Label("API 设置", systemImage: "gearshape") }
                Button(role: .destructive) { confirmClear = true } label: { Label("清除此文献的聊天", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 40) }
            .accessibilityLabel("AI 设置与聊天管理")
            Button { model.onClose?() } label: { Image(systemName: "xmark").frame(width: 30, height: 40) }
                .accessibilityLabel("关闭 AI 侧栏")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.messages.isEmpty { welcome }
                    ForEach(model.messages) { message in bubble(message) }
                    if model.isBusy {
                        HStack { ProgressView(); Text(model.messages.last?.status == .streaming ? "正在回答…" : "正在准备文档…").font(.caption).foregroundStyle(.secondary) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !model.messages.isEmpty {
                    Button { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down").font(.caption.bold()).padding(10).background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("跳到最新回复")
                    .padding(10)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("你好，我是 AI 阅读助手").font(.title3.bold())
            Text("围绕这篇文献提问，帮助你理解研究思路、方法和结论。回复中的页码可以点按跳转。")
                .foregroundStyle(.secondary)
            quickAction("总结文献", icon: "text.alignleft", prompt: "请总结本文的研究目的、方法、主要结果、创新点和局限，并引用对应页码。", scope: .document)
            quickAction("推荐相关问题", icon: "questionmark.bubble", prompt: "请基于本文推荐 5 个值得深入理解的问题，说明各问题对应的页码。", scope: .document)
            quickAction("解读当前页", icon: "doc.text.magnifyingglass", prompt: "请解释当前页的主要内容、术语和推理，指出需要留意的数据与局限。", scope: .page)
            quickAction("解释选中文字", icon: "text.cursor", prompt: "请解释选中文字的含义、关键术语及其在本文中的作用。", scope: .selection)
            Button("设置 DeepSeek / 其他兼容 API") { showSettings = true }.font(.callout)
        }
        .padding(16)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func quickAction(_ title: String, icon: String, prompt: String, scope: PDFReadingAssistantScope) -> some View {
        Button { focused = false; model.send(prompt, scope: scope) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(model.isBusy)
    }

    private func bubble(_ message: PDFReadingAssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == "assistant" {
                Label("AI", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.purple)
            }
            if let description = message.contextDescription {
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
            if message.content.isEmpty {
                Text(message.status == .streaming ? "等待模型回复…" : "未收到回复").foregroundStyle(.secondary)
            } else {
                Text(.init(message.content)).textSelection(.enabled).font(.body).lineSpacing(5)
            }
            if message.status == .stopped || message.status == .failed {
                Text(message.status == .stopped ? "已停止 · 内容可能不完整" : "回复中断 · 内容可能不完整").font(.caption).foregroundStyle(.secondary)
            }
            if message.role == "assistant", !message.content.isEmpty {
                Button { UIPasteboard.general.string = message.content } label: { Label("复制", systemImage: "doc.on.doc") }.font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.purple.opacity(0.12) : Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            if message.role == "user" {
                Button("再次提问") { model.draft = message.content }.disabled(model.isBusy)
            }
            Button("复制") { UIPasteboard.general.string = message.content }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提问范围").font(.caption).foregroundStyle(.secondary)
                Picker("提问范围", selection: $model.scope) {
                    ForEach(PDFReadingAssistantScope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).disabled(model.isBusy)
                Spacer(minLength: 0)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("API 设置")
            }
            if !model.status.isEmpty { Text(model.status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("问一个与此文献有关的问题…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5).focused($focused).padding(10)
                    .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(model.isBusy)
                Button {
                    focused = false
                    if model.isBusy { model.stop() } else { model.send() }
                } label: {
                    Image(systemName: model.isBusy ? "stop.fill" : "arrow.up").font(.headline)
                        .foregroundStyle(.white).frame(width: 38, height: 38).background(Color.purple, in: Circle())
                }
                .disabled(!model.isBusy && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(model.isBusy ? "停止回复" : "发送问题")
            }
            Text("所选范围的文本及近期对话将发送至你设置的 API。AI 可能出错，请核对原文。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

private struct PDFReadingAssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = PDFReadingAssistantConfiguration.saved.endpoint
    @State private var model = PDFReadingAssistantConfiguration.saved.model
    @State private var key = PDFReadingAssistantConfiguration.saved.apiKey
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("使用 DeepSeek 默认地址与模型") { endpoint = "https://api.deepseek.com"; model = "deepseek-flash" }
                    TextField("API Base URL", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Chat Completions 兼容 API") } footer: {
                    Text("DeepSeek 示例：https://api.deepseek.com，模型 deepseek-flash。其他服务可填写自己的 HTTPS 地址和模型；必须支持流式 Chat Completions。")
                }
                Section {
                    Text("密钥仅保存在本机钥匙串，不会写入聊天记录或同步至 Zotero。聊天记录按文献保存在本机；扫描页、图片和图表不进行 OCR 或视觉识别。")
                    Link("打开 DeepSeek 平台管理密钥与余额", destination: URL(string: "https://platform.deepseek.com/")!)
                    Button("移除此设备保存的 API Key", role: .destructive) { confirmDelete = true }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("AI 阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try PDFReadingAssistantConfiguration(endpoint: endpoint, model: model, apiKey: key).save()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .confirmationDialog("移除保存的 API Key？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("移除密钥", role: .destructive) {
                    do { try PDFReadingAssistantService.removeAPIKey(); key = "" } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
