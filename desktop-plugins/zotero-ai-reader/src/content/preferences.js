/* SPDX-License-Identifier: MIT */
(function initializeAIReaderPreferences() {
  "use strict";
  const root = document.getElementById("air-settings-pane");
  // Zotero loads a preference pane's scripts before inserting its XHTML.
  // Its post-insert lifecycle dispatches a load event on the root element.
  if (!root) {
    const onPaneLoad = event => {
      if (event.target?.id !== "air-settings-pane") return;
      document.removeEventListener("load", onPaneLoad, true);
      initializeAIReaderPreferences();
    };
    document.addEventListener("load", onPaneLoad, true);
    return;
  }
  if (root.getAttribute("data-ai-ready")) return;
  root.setAttribute("data-ai-ready", "true");
  const el = name => root.querySelector("#air-" + name);
  const api = Zotero.AIReader;
  if (!api) { el("settings-status").textContent = "插件尚未启动，请关闭设置并重启 Zotero。"; return; }
  const textFields = ["baseURL", "model", "language", "maxContextChars", "maxOutputTokens", "timeout"];
  const checkFields = ["stream", "noAuth"];
  const show = (text, error = false) => {
    el("settings-status").textContent = text;
    el("settings-status").classList.toggle("air-settings-error", error);
  };
  const keyStatus = () => {
    try {
      const exists = api.hasKey(el("baseURL").value);
      el("key-status").textContent = exists ? "此地址已有密钥。留空会保留；输入新密钥会替换。" : "此地址尚未保存密钥。";
      el("key").placeholder = exists ? "已保存（留空保留）" : "输入该服务的 API Key";
    } catch (_) { el("key-status").textContent = "请先填写有效的服务地址。"; }
  };
  try {
    const cfg = api.getSettings();
    for (const key of textFields) el(key).value = cfg[key];
    for (const key of checkFields) el(key).checked = cfg[key];
    keyStatus();
  } catch (e) { show(e.message, true); }
  el("profile").addEventListener("change", () => {
    const profile = api.profiles[el("profile").value];
    if (!profile) return;
    el("baseURL").value = profile.baseURL;
    el("model").value = profile.model;
    el("noAuth").checked = el("profile").value === "ollama";
    el("key").value = ""; el("removeKey").checked = false;
    keyStatus(); show("已填入配置，点击保存后生效。请确认模型已在你的服务中开通。");
  });
  el("baseURL").addEventListener("change", () => {
    // Never carry an unsaved key to a different service accidentally.
    el("key").value = ""; el("removeKey").checked = false; keyStatus();
  });
  let saving = false;
  async function save(test) {
    if (saving) return;
    saving = true; el("save").disabled = true; el("test").disabled = true;
    const cfg = {};
    for (const key of textFields) cfg[key] = el(key).value;
    for (const key of checkFields) cfg[key] = el(key).checked;
    try {
      const result = await api.saveSettings(cfg, el("key").value, el("removeKey").checked);
      el("key").value = ""; el("removeKey").checked = false; keyStatus();
      show(test ? "设置已保存，正在测试连接…" : `设置已保存。${result.hasKey ? "密钥已保存在 Zotero 密码管理器。" : cfg.noAuth ? "当前使用免密服务。" : "请补充 API Key 后再提问。"}`);
      if (test) {
        const response = await api.testConnection(cfg);
        show("连接成功。模型回复：" + response.text);
      }
    } catch (error) { show(String(error.message || "保存或连接失败。"), true); }
    finally { saving = false; el("save").disabled = false; el("test").disabled = false; }
  }
  el("save").addEventListener("click", () => save(false));
  el("test").addEventListener("click", () => save(true));
})();
