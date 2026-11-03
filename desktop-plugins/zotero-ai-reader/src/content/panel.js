/* SPDX-License-Identifier: MIT */
/* All output from the AI passes through Core.markdown (HTML escaped first). */
var AIReaderPanel = class {
  constructor(host, body, cssText) {
    this.host = host;
    this.body = body;
    this.doc = body.ownerDocument;
    this.item = null;
    this.attachmentID = null;
    this.state = null;
    this.destroyed = false;
    this.lastRendered = null;
    // Privileged Firefox documents sanitize innerHTML and remove form controls.
    // Parse this trusted, static UI template as XHTML so inputs survive in XUL windows.
    const markup = `<div xmlns="http://www.w3.org/1999/xhtml" class="air-panel">
      <div class="air-heading"><span class="air-wordmark">AI <span>READER</span></span><button type="button" class="air-link" data-action="settings">设置</button></div>
      <div class="air-paper" data-role="title">打开一篇文献开始阅读</div>
      <div class="air-toolbar">
        <label class="air-field">阅读材料
          <select data-role="source" aria-label="阅读材料来源">
            <option value="selection">选中文本</option>
            <option value="fulltext">附件全文</option>
            <option value="abstract">文献摘要</option>
            <option value="manual">手动粘贴</option>
          </select>
        </label>
        <button type="button" class="air-small" data-action="load">读取材料</button>
      </div>
      <textarea class="air-context" data-role="context" rows="4" aria-label="将发送给 AI 的阅读材料" placeholder="在 PDF 中选中文字，点击浮窗的「AI 助读」；也可在这里粘贴文本。"></textarea>
      <div class="air-meta" data-role="context-info">尚未读取材料</div>
      <div class="air-quick" aria-label="快捷阅读任务">
        <button type="button" data-task="explain">解释概念</button><button type="button" data-task="translate">翻译选段</button>
        <button type="button" data-task="summary">总结要点</button><button type="button" data-task="critique">分析方法</button>
      </div>
      <div class="air-chat" data-role="chat" role="log" aria-label="当前文献对话" aria-live="off"></div>
      <div class="air-compose"><textarea data-role="question" rows="3" maxlength="12000" aria-label="向 AI 提问" placeholder="对这段内容有什么疑问？\nCtrl + Enter 发送"></textarea></div>
      <div class="air-destination" data-role="destination"></div>
      <div class="air-actions"><button type="button" class="air-primary" data-action="send">发送</button><button type="button" class="air-stop" data-action="stop" hidden="hidden">停止</button><button type="button" data-action="copy">复制回答</button><button type="button" data-action="save">存为笔记</button><button type="button" class="air-link" data-action="clear">清空</button></div>
      <div class="air-status" data-role="status" role="status" aria-live="polite"></div>
      <div class="air-footnote">仅在点击发送或快捷任务时调用 AI。材料和当前文献的最近对话将发送至上方服务；回答请对照原文核实。</div></div>`;
    const parsed = new this.doc.defaultView.DOMParser().parseFromString(markup, "application/xhtml+xml");
    if (parsed.querySelector("parsererror")) throw new Error("AI 阅读边栏模板解析失败。");
    this.root = this.doc.importNode(parsed.documentElement, true);
    const style = this.doc.createElementNS("http://www.w3.org/1999/xhtml", "style");
    style.textContent = cssText;
    this.root.prepend(style);
    body.appendChild(this.root);
    this.el = role => this.root.querySelector(`[data-role="${role}"]`);
    this.root.addEventListener("click", event => {
      const button = event.target.closest("button");
      if (!button || button.disabled) return;
      const action = button.dataset.action, task = button.dataset.task;
      if (task) {
        this.el("question").value = AIReaderCore.ACTIONS[task];
        this.send();
      } else if (action === "settings") host.openSettings(this.doc.defaultView);
      else if (action === "load") this.load();
      else if (action === "send") this.send();
      else if (action === "stop") host.cancel(this.state);
      else if (action === "copy") this.copy();
      else if (action === "save") this.save();
      else if (action === "clear") this.clear();
    });
    this.el("question").addEventListener("keydown", event => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault(); this.send();
      }
    });
    this.el("question").addEventListener("input", () => { if (this.state) this.state.draft = this.el("question").value; });
    this.el("context").addEventListener("input", () => {
      if (!this.state || this.state.busy) return;
      this.state.source = "manual";
      this.state.context = this.el("context").value;
      this.state.contextLabel = "手动编辑";
      this.state.originalLength = this.state.context.length;
      this.state.truncated = false;
      this.el("source").value = "manual";
      this.updateContextInfo();
    });
    this.el("source").addEventListener("change", () => this.load());
  }
  bind(item, attachmentID) {
    if (this.destroyed) return;
    this.item = item;
    this.attachmentID = attachmentID;
    const state = this.host.getState(attachmentID || item.id);
    if (this.state !== state) {
      this.state = state;
      this.lastRendered = null;
      this.el("context").value = state.context;
      this.el("question").value = state.draft;
      this.el("source").value = state.source;
    }
    this.el("title").textContent = this.host.metadata(item).title || "未命名文献";
    this.el("title").title = this.el("title").textContent;
    this.update();
  }
  updateContextInfo() {
    if (!this.state) return;
    const s = this.state;
    let max = AIReaderCore.DEFAULTS.maxContextChars;
    try { max = this.host.getSettings().maxContextChars; } catch (_) {}
    const sendLength = Math.min(max, AIReaderCore.cleanText(s.context).length);
    this.el("context-info").textContent = `${s.contextLabel || "材料"} · 将发送 ${sendLength.toLocaleString()} 字符${s.truncated || s.context.length > max ? " · 已截断，非完整全文" : ""}`;
  }
  update() {
    if (this.destroyed || !this.state) return;
    const s = this.state;
    this.el("context").readOnly = s.busy || s.loading;
    this.el("source").disabled = s.busy || s.loading;
    for (const el of this.root.querySelectorAll('[data-task], [data-action="send"], [data-action="load"], [data-action="clear"]')) el.disabled = s.busy || s.loading;
    this.root.querySelector('[data-action="stop"]').hidden = !s.busy;
    this.root.querySelector('[data-action="save"]').disabled = s.busy || !s.messages.some(m => m.role === "assistant");
    this.root.querySelector('[data-action="copy"]').disabled = !s.messages.some(m => m.role === "assistant") && !s.partial;
    this.el("status").textContent = s.status || "";
    this.el("status").classList.toggle("air-error", Boolean(s.error));
    this.updateContextInfo();
    try {
      const cfg = this.host.getSettings();
      const url = new this.doc.defaultView.URL(AIReaderCore.endpoint(cfg.baseURL, this.doc.defaultView.URL));
      this.el("destination").textContent = `发送至 ${s.busy ? s.requestDestination : `${url.host} · ${cfg.model}`}`;
    } catch (_) { this.el("destination").textContent = "请先在设置中配置 AI 服务"; }
    const signature = JSON.stringify([s.messages, s.partial, s.busy]);
    if (this.lastRendered === signature) return;
    this.lastRendered = signature;
    const chat = this.el("chat");
    const atBottom = chat.scrollHeight - chat.scrollTop - chat.clientHeight < 65;
    chat.replaceChildren();
    if (!s.messages.length && !s.busy) {
      const welcome = this.doc.createElementNS("http://www.w3.org/1999/xhtml", "div");
      welcome.className = "air-welcome";
      welcome.innerHTML = "<b>读懂下一段。</b><p>选取材料，解释一个概念，或从研究方法开始提问。</p>";
      chat.appendChild(welcome);
    }
    for (const message of s.messages) this.addMessage(chat, message.role, message.content);
    if (s.busy) this.addMessage(chat, "assistant", s.partial || "正在阅读材料…");
    if (atBottom || s.messages.length <= 1) chat.scrollTop = chat.scrollHeight;
  }
  addMessage(chat, role, content) {
    const node = this.doc.createElementNS("http://www.w3.org/1999/xhtml", "article");
    node.className = `air-message air-${role}`;
    const title = this.doc.createElementNS("http://www.w3.org/1999/xhtml", "div");
    title.className = "air-message-label";
    title.textContent = role === "user" ? "你" : "AI READER";
    const text = this.doc.createElementNS("http://www.w3.org/1999/xhtml", "div");
    text.className = "air-message-text";
    text.innerHTML = AIReaderCore.markdown(content);
    node.append(title, text);
    chat.appendChild(node);
  }
  async load() {
    if (!this.state || this.state.busy || this.state.loading) return;
    const state = this.state, id = this.attachmentID, item = this.item;
    const source = this.el("source").value;
    state.loading = true; state.status = "正在读取材料…"; state.error = false;
    this.host.refresh(state);
    try {
      const material = await this.host.readContext({ source, attachmentID: id, item, state });
      Object.assign(state, material, { source, status: material.text ? "材料已就绪，可编辑后再发送。" : "未读取到文字；请改用选中文本或手动粘贴。" });
      state.context = material.text;
      for (const panel of this.host.panels) if (panel.state === state) {
        panel.el("context").value = state.context;
        panel.el("source").value = source;
      }
    } catch (error) { state.status = AIReaderCore.redactError(error); state.error = true; }
    finally { state.loading = false; this.host.refresh(state); }
  }
  send() {
    if (!this.state || this.state.busy || this.state.loading) return;
    const question = this.el("question").value.trim();
    if (!question) { this.state.status = "请先输入问题，或点击一个快捷任务。"; this.update(); return; }
    this.host.ask({ state: this.state, item: this.item, attachmentID: this.attachmentID, question });
  }
  async copy() {
    const answer = this.state?.partial || [...(this.state?.messages || [])].reverse().find(m => m.role === "assistant")?.content;
    if (!answer) return;
    try { await this.host.copy(answer); this.state.status = "回答已复制。"; this.host.refresh(this.state); }
    catch (e) { this.state.status = AIReaderCore.redactError(e); this.state.error = true; this.update(); }
  }
  async save() {
    if (!this.state || this.state.busy) return;
    const state = this.state;
    try {
      await this.host.saveNote({ state, item: this.item, attachmentID: this.attachmentID });
      state.status = "已保存到当前文献库的 Zotero 笔记。"; state.error = false;
    } catch (e) { state.status = AIReaderCore.redactError(e); state.error = true; }
    this.host.refresh(state);
  }
  clear() {
    if (!this.state || this.state.busy || this.state.loading) return;
    if (this.state.messages.length && !this.doc.defaultView.confirm("清空当前文献的对话？已保存的 Zotero 笔记会保留。")) return;
    this.state.messages = []; this.state.partial = ""; this.state.status = "已清空当前文献的对话。"; this.state.error = false;
    this.host.refresh(this.state);
  }
  destroy() { this.destroyed = true; this.root.remove(); this.state = null; }
};
