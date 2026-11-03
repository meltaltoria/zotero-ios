/* SPDX-License-Identifier: MIT */
/* Zotero adapter: sidebar lifecycle, local credentials, attachment text, HTTP and notes. */
var AIReaderPlugin = class {
  constructor({ id, version, rootURI }) {
    this.id = id; this.version = version; this.rootURI = rootURI;
    this.panels = new Set(); this.states = new Map(); this.selections = new Map();
    this.windows = new Set(); this.requests = new Set(); this.prefPrefix = "extensions.zotero.aiReader.";
    this.selectionButtons = new Set();
    this.stopped = false;
    this.selectionListener = event => this.onSelection(event);
  }
  async start() {
    this.css = await Zotero.File.getContentsAsync(this.rootURI + "content/panel.css");
    for (const win of Zotero.getMainWindows()) this.addWindow(win);
    this.preferenceID = await Zotero.PreferencePanes.register({
      pluginID: this.id, id: "ai-reader-preferences", label: "AI 阅读助手",
      src: this.rootURI + "content/preferences.xhtml",
      scripts: [this.rootURI + "content/preferences.js"],
      stylesheets: [this.rootURI + "content/preferences.css"]
    });
    this.sectionID = Zotero.ItemPaneManager.registerSection({
      paneID: "ai-reader-section", pluginID: this.id,
      header: { l10nID: "ai-reader-title", icon: this.rootURI + "content/icon.svg" },
      sidenav: { l10nID: "ai-reader-sidenav", icon: this.rootURI + "content/icon.svg" },
      onInit: ({ doc }) => this.addLocalization(doc),
      onItemChange: ({ item, setEnabled }) => setEnabled(Boolean(item && (item.isRegularItem() || item.isAttachment()))),
      onRender: args => this.render(args),
      onDestroy: ({ body }) => {
        const panel = [...this.panels].find(x => x.body === body);
        if (panel) { panel.destroy(); this.panels.delete(panel); }
      }
    });
    if (!this.sectionID) throw new Error("无法注册 AI 阅读边栏，请确认 Zotero 版本为 7 或更高。");
    Zotero.Reader.registerEventListener("renderTextSelectionPopup", this.selectionListener, this.id);
    // Only a narrow public bridge is exposed to the settings pane (no stored key getter).
    Zotero.AIReader = {
      owner: this,
      getSettings: () => this.getSettings(),
      hasKey: baseURL => this.hasKey(baseURL),
      saveSettings: (config, key, removeKey) => this.saveSettings(config, key, removeKey),
      testConnection: config => this.testConnection(config),
      profiles: AIReaderCore.PROFILES
    };
  }
  addLocalization(doc) {
    if (!doc?.l10n || doc.querySelector('link[data-ai-reader-l10n]')) return;
    const link = doc.createElementNS("http://www.w3.org/1999/xhtml", "link");
    link.setAttribute("rel", "localization");
    link.setAttribute("href", "ai-reader.ftl");
    link.setAttribute("data-ai-reader-l10n", "true");
    (doc.head || doc.documentElement).appendChild(link);
  }
  addWindow(win) {
    if (this.windows.has(win)) return;
    this.windows.add(win);
    this.addLocalization(win.document);
    const doc = win.document;
    const popup = doc.getElementById("menu_ToolsPopup");
    if (popup && !doc.getElementById("ai-reader-settings-menu")) {
      const entry = doc.createXULElement("menuitem");
      entry.id = "ai-reader-settings-menu";
      entry.setAttribute("label", "AI 阅读助手设置…");
      entry.addEventListener("command", () => this.openSettings(win));
      popup.appendChild(entry);
    }
  }
  removeWindow(win) {
    win.document.getElementById("ai-reader-settings-menu")?.remove();
    win.document.querySelector('link[data-ai-reader-l10n]')?.remove();
    for (const panel of this.panels) if (panel.doc.defaultView === win) { panel.destroy(); this.panels.delete(panel); }
    this.windows.delete(win);
  }
  getSettings() {
    const config = {};
    for (const [key, fallback] of Object.entries(AIReaderCore.DEFAULTS)) {
      let stored;
      try { stored = Zotero.Prefs.get(this.prefPrefix + key, true); } catch (_) {}
      config[key] = stored === undefined ? fallback : stored;
    }
    const win = Zotero.getMainWindow();
    return AIReaderCore.settings(config, win.URL);
  }
  credentialRealm(baseURL) {
    return AIReaderCore.endpoint(baseURL, Zotero.getMainWindow().URL);
  }
  findLogins(baseURL) {
    return Services.logins.findLogins("chrome://ai-reader", null, this.credentialRealm(baseURL));
  }
  hasKey(baseURL) { return this.findLogins(baseURL).length > 0; }
  getKey(baseURL) { return this.findLogins(baseURL)[0]?.password || ""; }
  async saveSettings(config, newKey = "", removeKey = false) {
    const normalized = AIReaderCore.settings(config, Zotero.getMainWindow().URL);
    const secret = String(newKey).trim();
    if (secret && /[\r\n]/.test(secret)) throw new Error("API Key 不能包含换行符。");
    if (secret.length > 4096) throw new Error("API Key 过长，请检查输入。");
    // Credentials are bound to the complete endpoint; changing service never reuses another service's key.
    const previous = this.findLogins(normalized.baseURL);
    if (secret && !removeKey) {
      const login = Components.classes["@mozilla.org/login-manager/loginInfo;1"].createInstance(Components.interfaces.nsILoginInfo);
      login.init("chrome://ai-reader", null, this.credentialRealm(normalized.baseURL), "api-key", secret, "", "");
      if (previous.length) Services.logins.modifyLogin(previous[0], login);
      else if (Services.logins.addLoginAsync) await Services.logins.addLoginAsync(login);
      else Services.logins.addLogin(login);
    } else if (removeKey) {
      for (const login of previous) Services.logins.removeLogin(login);
    }
    for (const key of Object.keys(AIReaderCore.DEFAULTS)) Zotero.Prefs.set(this.prefPrefix + key, normalized[key], true);
    for (const panel of this.panels) panel.update();
    return { hasKey: this.hasKey(normalized.baseURL) };
  }
  openSettings(win = Zotero.getMainWindow()) {
    const main = win?.ZoteroPane ? win : Zotero.getMainWindow();
    main.Zotero.Utilities.Internal.openPreferences("ai-reader-preferences");
  }
  metadata(item) {
    let parent = item;
    if (item?.isAttachment() && item.parentID) parent = Zotero.Items.get(item.parentID) || item;
    let title = "", authors = "", year = "";
    try {
      title = parent.getField("title");
      authors = parent.getCreators().map(c => [c.firstName, c.lastName].filter(Boolean).join(" ")).join(", ");
      year = (parent.getField("date") || "").match(/\b\d{4}\b/)?.[0] || "";
    } catch (_) {}
    return { title, authors, year };
  }
  attachmentFor(item, body) {
    const win = body.ownerDocument.defaultView;
    const details = body.closest("item-details");
    const tabID = details?.tabID || details?.dataset?.tabId;
    const reader = tabID ? Zotero.Reader.getByTabID(tabID) : null;
    if (reader) return reader.itemID;
    if (!win.Zotero_Tabs) {
      const standalone = Zotero.Reader._readers?.find(r => r._window === win);
      if (standalone) return standalone.itemID;
    }
    if (item.isAttachment()) return item.id;
    const ids = item.getAttachments?.() || [];
    return ids.find(id => Zotero.Items.get(id)?.attachmentContentType === "application/pdf") || ids.find(id => {
      const child = Zotero.Items.get(id);
      return child?.isFileAttachment?.();
    }) || null;
  }
  render({ body, item, setEnabled }) {
    if (this.stopped || !item || !(item.isRegularItem() || item.isAttachment())) { setEnabled(false); return; }
    setEnabled(true);
    this.addLocalization(body.ownerDocument);
    let panel = [...this.panels].find(x => x.body === body);
    if (!panel) { panel = new AIReaderPanel(this, body, this.css); this.panels.add(panel); }
    panel.bind(item, this.attachmentFor(item, body));
  }
  getState(key) {
    if (!this.states.has(key)) {
      // Avoid an unbounded session cache. Never evict a running request or a visible panel.
      if (this.states.size >= 80) {
        for (const [id, state] of this.states) {
          if (!state.busy && ![...this.panels].some(p => p.state === state)) { this.states.delete(id); break; }
        }
      }
      this.states.set(key, { key, messages: [], partial: "", draft: "", context: "", contextLabel: "尚未读取材料",
        originalLength: 0, truncated: false, source: "selection", busy: false, loading: false,
        error: false, status: "先配置 AI 服务，再选择阅读材料。", cancel: null, lastContext: "" });
    }
    return this.states.get(key);
  }
  refresh(state) { if (!this.stopped) for (const panel of this.panels) if (panel.state === state) panel.update(); }
  onSelection({ reader, doc, params, append }) {
    if (this.stopped) return;
    const text = AIReaderCore.cleanText(params?.annotation?.text);
    if (!text) return;
    const pos = params.annotation.position;
    const page = Number.isInteger(pos?.pageIndex) ? pos.pageIndex + 1 : null;
    const value = { text, page };
    this.selections.set(reader.itemID, value);
    if (this.selections.size > 120) this.selections.delete(this.selections.keys().next().value);
    const button = doc.createElement("button");
    button.type = "button"; button.textContent = "AI 助读";
    button.setAttribute("title", "把选中文本放入 AI 边栏（不会自动发送）");
    button.style.cssText = "margin:4px 6px;padding:5px 10px;border:1px solid #7396df;border-radius:5px;background:transparent;color:inherit;cursor:pointer;font:inherit;";
    button.addEventListener("click", event => {
      event.preventDefault(); event.stopPropagation();
      if (this.stopped) return;
      const state = this.getState(reader.itemID);
      if (state.busy || state.loading) { state.status = "请先停止生成或等待读取完成，再更换阅读材料。"; this.refresh(state); return; }
      const material = this.selectionContext(value);
      Object.assign(state, material, { context: material.text, source: "selection", status: "已放入选中文本。点击快捷任务或输入问题后发送。", error: false });
      for (const panel of this.panels) if (panel.state === state) {
        panel.el("context").value = state.context;
        panel.el("source").value = "selection";
      }
      this.openSidebar(reader);
      this.refresh(state);
    });
    for (const old of this.selectionButtons) if (!old.isConnected) this.selectionButtons.delete(old);
    this.selectionButtons.add(button);
    append(button);
  }
  openSidebar(reader) {
    const win = reader._window || Zotero.getMainWindow();
    this.addLocalization(win.document);
    const context = win.document.getElementById("zotero-context-pane");
    if (context) context.collapsed = false;
    const splitter = win.document.getElementById("zotero-context-splitter");
    if (splitter) splitter.setAttribute("state", "open");
    const details = reader.tabID ? win.document.getElementById(reader.tabID + "-context") : null;
    const container = details || win.document.querySelector("item-details:not([hidden])");
    if (container) {
      container.pinnedPane = this.sectionID;
      container.scrollToPane?.(this.sectionID);
    }
    const pane = container?.querySelector(`[data-pane="${this.sectionID}"]`);
    if (pane) { pane.open = true; pane.scrollIntoView({ block: "nearest" }); }
  }
  selectionContext(value) {
    if (!value?.text) throw new Error("请先在阅读器中选中文字，再点击浮窗中的「AI 助读」。");
    const raw = `${value.page ? `[p. ${value.page}]\n` : ""}${value.text}`;
    const excerpt = AIReaderCore.clip(raw, this.getSettings().maxContextChars);
    return { ...excerpt, contextLabel: value.page ? `选中文本 · 物理页 ${value.page}` : "选中文本" };
  }
  async readContext({ source, attachmentID, item, state }) {
    if (source === "selection") return this.selectionContext(this.selections.get(attachmentID));
    if (source === "manual") return { text: state.context, contextLabel: "手动粘贴", originalLength: state.context.length, truncated: state.truncated };
    let text = "", label = "";
    if (source === "abstract") {
      const parent = item.isAttachment() && item.parentID ? Zotero.Items.get(item.parentID) : item;
      text = parent.getField("abstractNote") || ""; label = "文献摘要";
    } else if (source === "fulltext") {
      const attachment = attachmentID && Zotero.Items.get(attachmentID);
      if (!attachment?.isAttachment()) throw new Error("当前文献没有可读取的附件。请先添加 PDF，或改用摘要、手动粘贴。");
      if (!(await attachment.getFilePathAsync())) throw new Error("附件尚未下载或文件不存在；请先在 Zotero 中打开附件。");
      text = await attachment.attachmentText; label = "附件全文（无逐页定位）";
      if (!text?.trim()) throw new Error("未提取到文字。扫描版 PDF 需先做 OCR；也可手动粘贴文本。");
    }
    return { ...AIReaderCore.clip(text, this.getSettings().maxContextChars), contextLabel: label };
  }
  async ask({ state, item, attachmentID, question }) {
    if (state.busy || state.loading || this.stopped) return;
    let secret = "", added = false;
    try {
      const config = this.getSettings();
      secret = config.noAuth ? "" : this.getKey(config.baseURL);
      if (!secret && !config.noAuth) throw new Error("尚未为该服务保存 API Key。请打开设置填写；免密服务可勾选「此服务无需密钥」。");
      if (!state.context.trim()) throw new Error("请先读取或粘贴阅读材料，再向 AI 提问。");
      const built = AIReaderCore.buildMessages({ metadata: this.metadata(item), context: state.context,
        contextTruncated: state.truncated, history: state.messages, question, language: config.language, maxContextChars: config.maxContextChars });
      state.busy = true; state.error = false; state.partial = ""; state.status = "正在连接 AI 服务…";
      state.requestDestination = `${new (Zotero.getMainWindow().URL)(AIReaderCore.endpoint(config.baseURL, Zotero.getMainWindow().URL)).host} · ${config.model}`;
      state.messages.push({ role: "user", content: question }); added = true;
      state.draft = "";
      for (const panel of this.panels) if (panel.state === state) panel.el("question").value = "";
      this.refresh(state);
      let lastPaint = 0;
      const result = await this.request(config, secret, built.messages, text => {
        state.partial = text; state.status = "正在生成…";
        if (Date.now() - lastPaint >= 60) { lastPaint = Date.now(); this.refresh(state); }
      }, cancel => { state.cancel = cancel; });
      state.messages.push({ role: "assistant", content: result.text });
      state.partial = ""; state.lastContext = built.excerpt.text;
      state.lastModel = config.model; state.lastEndpoint = AIReaderCore.endpoint(config.baseURL, Zotero.getMainWindow().URL);
      state.lastAttachmentID = attachmentID;
      state.status = result.finishReason === "length" ? "回答达到输出上限，可提高设置中的 Token 上限后重试。" : "回答完成。请对照原文核实。";
    } catch (error) {
      if (added) {
        if (state.partial) {
          state.messages.push({ role: "assistant", content: state.partial + "\n\n（本次生成未完成。）" });
          state.lastContext = AIReaderCore.clip(state.context, AIReaderCore.DEFAULTS.maxContextChars).text;
          state.lastAttachmentID = attachmentID;
        } else {
          state.messages.pop(); state.draft = question;
          for (const panel of this.panels) if (panel.state === state) panel.el("question").value = question;
        }
      }
      state.partial = "";
      state.status = error?.name === "AbortError" ? "已停止生成。" : AIReaderCore.redactError(error, secret);
      state.error = error?.name !== "AbortError";
    } finally {
      state.busy = false; state.cancel = null;
      // Keep complete pairs so that later requests never merge documents or invalid roles.
      if (state.messages.length > 24) state.messages = state.messages.slice(-24);
      this.refresh(state);
    }
  }
  request(config, secret, messages, onDelta = () => {}, setCancel = () => {}) {
    if (this.stopped) return Promise.reject(new Error("插件已停用。"));
    const win = Zotero.getMainWindow();
    const url = AIReaderCore.endpoint(config.baseURL, win.URL);
    return new Promise((resolve, reject) => {
      const xhr = new win.XMLHttpRequest();
      let settled = false, cursor = 0;
      const decoder = new AIReaderCore.SSEDecoder(onDelta);
      this.requests.add(xhr);
      const finish = (error, value) => {
        if (settled) return;
        settled = true; this.requests.delete(xhr);
        xhr.onload = xhr.onerror = xhr.ontimeout = xhr.onabort = xhr.onprogress = null;
        error ? reject(error) : resolve(value);
      };
      const fail = error => { finish(error); try { xhr.abort(); } catch (_) {} };
      const progress = () => {
        if (xhr.status < 200 || xhr.status >= 300) return;
        if (xhr.responseText.length > 2 * 1024 * 1024) { fail(new Error("AI 回答过长，已停止接收。请减小输出 Token 上限。")); return; }
        const isSSE = /text\/event-stream/i.test(xhr.getResponseHeader("Content-Type") || "");
        if (!config.stream || !isSSE) return;
        try { decoder.feed(xhr.responseText.slice(cursor)); cursor = xhr.responseText.length; }
        catch (error) { fail(new Error(AIReaderCore.redactError(error, secret))); }
      };
      try {
        xhr.open("POST", url, true);
        xhr.timeout = config.timeout * 1000;
        xhr.withCredentials = false;
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.setRequestHeader("Accept", config.stream ? "text/event-stream, application/json" : "application/json");
        if (secret) xhr.setRequestHeader("Authorization", "Bearer " + secret);
        xhr.onprogress = progress;
        xhr.onload = () => {
          if (settled) return;
          if (xhr.status < 200 || xhr.status >= 300) {
            const meaning = { 400: "请求参数或模型不受支持", 401: "API Key 无效", 403: "没有访问权限", 404: "接口地址或模型不存在", 429: "额度不足或请求过于频繁", 500: "服务内部错误", 502: "服务网关错误", 503: "服务暂不可用" }[xhr.status] || "AI 服务请求失败";
            let detail = "";
            try { const obj = JSON.parse(xhr.responseText); detail = String(obj.error?.message || "").slice(0, 500); } catch (_) {}
            finish(new Error(AIReaderCore.redactError(new Error(`HTTP ${xhr.status}：${meaning}${detail ? "。" + detail : "。"}`), secret))); return;
          }
          try {
            progress(); if (settled) return;
            let result;
            if (/text\/event-stream/i.test(xhr.getResponseHeader("Content-Type") || "")) result = decoder.finish();
            else result = AIReaderCore.parseCompletion(xhr.responseText);
            if (!result.text?.trim()) throw new Error("模型没有返回可显示的回答。请尝试关闭流式输出或增加输出 Token 上限。");
            finish(null, result);
          } catch (error) { finish(new Error(AIReaderCore.redactError(error, secret))); }
        };
        xhr.onerror = () => finish(new Error("无法连接 AI 服务。请检查服务地址、网络、代理和本地模型是否已启动。"));
        xhr.ontimeout = () => finish(new Error(`AI 请求在 ${config.timeout} 秒后超时，可在设置中延长等待时间。`));
        xhr.onabort = () => { const e = new Error("已停止生成。"); e.name = "AbortError"; finish(e); };
        setCancel(() => xhr.abort());
        xhr.send(JSON.stringify(AIReaderCore.requestBody(config, messages)));
      } catch (error) { fail(new Error(AIReaderCore.redactError(error, secret))); }
    });
  }
  cancel(state) { state?.cancel?.(); }
  async testConnection(config) {
    const normalized = AIReaderCore.settings(config, Zotero.getMainWindow().URL);
    const key = normalized.noAuth ? "" : this.getKey(normalized.baseURL);
    if (!key && !normalized.noAuth) throw new Error("请先保存当前服务的 API Key，再测试连接。");
    const result = await this.request({ ...normalized, maxOutputTokens: 128 }, key,
      [{ role: "user", content: "Reply only: OK" }]);
    return { text: result.text.slice(0, 200) };
  }
  copy(text) { return Zotero.Utilities.Internal.copyTextToClipboard(text); }
  async saveNote({ state, item, attachmentID }) {
    if (!state.messages.some(m => m.role === "assistant")) throw new Error("尚无可保存的 AI 回答。");
    const library = Zotero.Libraries.get(item.libraryID);
    if (!library?.editable || item.deleted) throw new Error("当前文献库只读，无法添加笔记；可以复制回答。");
    const attachment = attachmentID && Zotero.Items.get(attachmentID);
    const parent = item.isRegularItem() ? item : (item.parentID ? Zotero.Items.get(item.parentID) : null);
    const note = new Zotero.Item("note"); note.libraryID = item.libraryID;
    if (parent?.isRegularItem()) note.parentID = parent.id;
    const e = AIReaderCore.escapeHTML;
    const link = attachment ? `zotero://open-pdf/${library.libraryType === "group" ? "groups/" + library.libraryTypeID : "library"}/items/${attachment.key}` : "";
    const content = state.messages.map(m => `<h3>${m.role === "user" ? "问题" : "AI 回答"}</h3>${AIReaderCore.markdown(m.content)}`).join("\n");
    note.setNote(`<div data-schema-version="9"><h1>AI 阅读笔记</h1><p>${e(this.metadata(item).title)}</p><p>创建于 ${e(new Date().toLocaleString())} · 模型 ${e(state.lastModel || this.getSettings().model)}</p><p>AI 生成内容，请对照原文核实。</p>${link ? `<p><a href="${e(link)}">打开文献附件</a></p>` : ""}<h2>最近一次使用的阅读材料</h2><blockquote>${e(state.lastContext || state.context).replace(/\n/g, "<br/>")}</blockquote><h2>阅读对话</h2>${content}</div>`);
    if (!parent && attachment?.getCollections) note.setCollections(attachment.getCollections());
    return note.saveTx();
  }
  stop() {
    if (this.stopped) return;
    this.stopped = true;
    for (const xhr of this.requests) { try { xhr.abort(); } catch (_) {} }
    this.requests.clear();
    for (const button of this.selectionButtons) { try { button.remove(); } catch (_) {} }
    this.selectionButtons.clear();
    Zotero.Reader.unregisterEventListener("renderTextSelectionPopup", this.selectionListener);
    if (this.sectionID) Zotero.ItemPaneManager.unregisterSection(this.sectionID);
    if (this.preferenceID) Zotero.PreferencePanes.unregister(this.preferenceID);
    for (const panel of this.panels) panel.destroy();
    this.panels.clear();
    for (const win of [...this.windows]) this.removeWindow(win);
    this.states.clear(); this.selections.clear();
    if (Zotero.AIReader?.owner === this) delete Zotero.AIReader;
  }
};
