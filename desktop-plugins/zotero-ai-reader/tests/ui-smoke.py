#!/usr/bin/env python3
"""Browser UI and actual HTTP integration; Zotero library/storage interfaces use fixtures."""
from pathlib import Path
import importlib.util
import json
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_fixture', ROOT / 'tests' / 'runtime-smoke.py')
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)

class Server(SimpleHTTPRequestHandler):
    requests = []
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(ROOT), **kwargs)
    def log_message(self, *_): pass
    def do_POST(self):
        self.requests.append(self.path)
        fixture.Provider.do_POST(self)

MOCK = r'''async () => {
  const prefs = new Map(), logins = [], items = new Map(), notes = [], listeners = [];
  const item = (id, attachmentID) => ({ id, libraryID: 1, deleted: false,
    isRegularItem: () => true, isAttachment: () => false,
    getField: key => ({ title: `Paper ${id}`, date: '2026', abstractNote: 'Abstract fixture.' })[key] || '',
    getCreators: () => [{ firstName: 'Test', lastName: 'Author' }], getAttachments: () => [attachmentID] });
  for (const [id, aid] of [[1, 11], [2, 22]]) {
    items.set(id, item(id, aid));
    items.set(aid, { id: aid, key: 'PDF' + aid, libraryID: 1, parentID: id,
      isAttachment: () => true, isFileAttachment: () => true, isRegularItem: () => false,
      attachmentContentType: 'application/pdf', getFilePathAsync: async () => '/fixture.pdf',
      attachmentText: Promise.resolve('Controlled reading experiment. ' + 'Text '.repeat(9000)) });
  }
  window.document.createXULElement = tag => document.createElement(tag);
  window.Zotero = {
    getMainWindow: () => window, getMainWindows: () => [window],
    Prefs: { get: k => prefs.get(k), set: (k, v) => prefs.set(k, v) },
    File: { getContentsAsync: url => fetch(url).then(r => r.text()) },
    PreferencePanes: { pluginPanes: [], async register(o) { this.pluginPanes.push(o); return o.id; }, unregister(id) { this.pluginPanes = this.pluginPanes.filter(x => x.id !== id); } },
    ItemPaneManager: { registerSection: o => { window.sectionOptions = o; return 'ai-reader-local-zotero-ai-reader-section'; }, unregisterSection: id => { window.unregistered = id; } },
    Reader: { _readers: [], getByTabID: () => null, registerEventListener: (...a) => listeners.push(a), unregisterEventListener: () => { listeners.length = 0; } },
    Items: { get: id => items.get(id) }, Libraries: { get: () => ({ editable: true, libraryType: 'user' }) },
    Utilities: { Internal: { copyTextToClipboard: text => { window.clipboardText = text; }, openPreferences: id => { window.openedPreferences = id; } } },
    Item: class { constructor(type) { this.type = type; } setNote(text) { this.note = text; } setCollections(c) { this.collections = c; } async saveTx() { notes.push(this); return notes.length + 100; } }
  };
  window.Services = {
    io: { newURI: url => ({ spec: url }), newChannelFromURI: uri => uri.spec },
    scriptSecurityManager: { getSystemPrincipal: () => ({}) },
    logins: {
    findLogins: (origin, form, realm) => logins.filter(x => x.origin === origin && x.realm === realm),
    addLoginAsync: async login => logins.push(login),
    modifyLogin: (old, next) => { logins[logins.indexOf(old)] = next; },
    removeLogin: old => logins.splice(logins.indexOf(old), 1)
  } };
  window.Components = { classes: { '@mozilla.org/login-manager/loginInfo;1': { createInstance: () => ({ init(origin, form, realm, user, password) { Object.assign(this, { origin, realm, password }); } }) } }, interfaces: { nsILoginInfo: {}, nsILoadInfo: { SEC_ALLOW_CROSS_ORIGIN_SEC_CONTEXT_IS_NULL: 0 }, nsIContentPolicy: { TYPE_OTHER: 1 } } };
  const manifest = await fetch('/src/manifest.json').then(r => r.json());
  window.host = new AIReaderPlugin({ id: 'ai-reader@local.zotero', version: manifest.version, rootURI: location.origin + '/src/' });
  await host.start();
  await host.saveSettings({ ...host.getSettings(), baseURL: location.origin + '/v1', model: 'fixture-model', noAuth: true });
  const body = document.querySelector('#panel-body');
  host.render({ body, item: items.get(1), setEnabled: value => { window.enabled = value; } });
  window.panel = [...host.panels][0];
  window.fixtures = { prefs, logins, items, notes, listeners };
}'''

def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    checks = []
    def check(name, value):
        if not value: raise AssertionError(name)
        checks.append(name)
    try:
      with sync_playwright() as p:
        browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
        page = browser.new_page(viewport={'width': 680, 'height': 980})
        errors = []; page.on('pageerror', lambda e: errors.append(str(e)))
        page.goto(base + '/src/manifest.json')
        page.set_content('<div id="menu_ToolsPopup"></div><div id="panel-body" style="width:330px;margin:15px auto"></div>')
        for name in ('core.js', 'panel.js', 'host.js'): page.add_script_tag(path=str(ROOT / 'src' / 'content' / name))
        page.evaluate(MOCK)
        check('no request sent on startup', len(Server.requests) == 0)
        check('sidebar rendered', page.locator('[data-action="send"]').is_visible())
        page.locator('[data-action="settings"]').click()
        check('settings route', page.evaluate('openedPreferences') == 'ai-reader-preferences')
        page.evaluate('''() => {
          let popupButton;
          host.onSelection({ reader: { itemID: 11, _window: window }, doc: document,
            params: { annotation: { text: 'Selected fixture text', position: { pageIndex: 2 } } },
            append: button => { popupButton = button; document.body.append(button); } });
          popupButton.click();
        }''')
        check('selection popup transfers page context without sending', page.evaluate('panel.state.context === "[p. 3]\\nSelected fixture text"') and len(Server.requests) == 0)
        page.locator('[data-role="source"]').select_option('fulltext')
        page.wait_for_function('!panel.state.loading')
        check('fulltext read bounded and truncation shown', page.evaluate('panel.state.context.length === 24000 && panel.state.truncated') and '已截断' in page.locator('[data-role="context-info"]').inner_text())
        page.locator('[data-role="question"]').fill('请解释这段内容')
        page.locator('[data-role="question"]').press('Control+Enter')
        page.wait_for_function('!panel.state.busy && panel.state.messages.length === 2')
        check('real HTTP streaming answer displayed', '测试回答' in page.locator('[data-role="chat"]').inner_text())
        check('AI HTML rendered as harmless text', page.locator('.air-chat img, .air-chat script, .air-chat iframe').count() == 0)
        page.locator('[data-action="copy"]').click()
        check('copy latest answer', page.evaluate('clipboardText.includes("测试回答")'))
        page.locator('[data-action="save"]').click()
        page.wait_for_function('fixtures.notes.length === 1')
        check('save document child note', page.evaluate('fixtures.notes[0].parentID === 1 && !fixtures.notes[0].note.includes("<img")'))
        page.evaluate('panel.bind(fixtures.items.get(2),22)')
        check('document switch isolates chat and context', page.evaluate('panel.state.messages.length === 0 && panel.state.context === ""'))
        page.evaluate('panel.bind(fixtures.items.get(1),11)')
        check('return restores original conversation', page.evaluate('panel.state.messages.length === 2'))
        page.locator('[data-role="question"]').fill('slow')
        page.locator('[data-action="send"]').click()
        page.wait_for_function('panel.state.partial.length > 0')
        page.locator('[data-action="stop"]').click()
        page.wait_for_function('!panel.state.busy')
        check('cancel preserves partial response and releases request', page.evaluate('host.requests.size === 0 && panel.state.status.includes("已停止") && panel.state.messages.length === 4'))
        page.locator('[data-role="question"]').fill('error401')
        page.locator('[data-action="send"]').click()
        page.wait_for_function('!panel.state.busy')
        check('HTTP failure keeps question for retry', page.evaluate('panel.state.error && panel.state.draft === "error401" && panel.state.messages.length === 4'))
        page.locator('[data-role="question"]').fill('nonstream')
        page.evaluate('host.saveSettings({...host.getSettings(),stream:false})')
        page.locator('[data-action="send"]').click()
        page.wait_for_function('!panel.state.busy && panel.state.messages.length === 6')
        check('nonstream request completes', page.evaluate('!panel.state.error'))
        page.screenshot(path=str(ROOT / 'tests' / 'artifacts' / 'sidebar-preview.png'), full_page=True)
        # Reproduce Zotero's order: scripts run before the XHTML fragment exists.
        page.add_script_tag(path=str(ROOT / 'src' / 'content' / 'preferences.js'))
        page.evaluate('''async () => {
          const xml = await fetch('/src/content/preferences.xhtml').then(r => r.text());
          const fragment = new DOMParser().parseFromString(xml,'application/xml');
          function adapt(node) {
            if (node.nodeType !== 1) return document.importNode(node,true);
            const html = node.namespaceURI === 'http://www.w3.org/1999/xhtml';
            const out = document.createElement(html ? node.localName : 'div');
            for (const a of node.attributes) if (!a.name.startsWith('xmlns')) out.setAttribute(a.name,a.value);
            for (const child of node.childNodes) out.append(adapt(child));
            return out;
          }
          const root = adapt(fragment.documentElement);
          document.body.append(root);
          root.dispatchEvent(new Event('load'));
        }''')
        page.add_style_tag(path=str(ROOT / 'src' / 'content' / 'preferences.css'))
        check('settings load current config', page.locator('#air-model').input_value() == 'fixture-model')
        check('settings never show saved secret', page.locator('#air-key').input_value() == '')
        page.locator('#air-profile').select_option('deepseek')
        check('provider preset fills endpoint and model', page.locator('#air-baseURL').input_value() == 'https://api.deepseek.com/v1' and page.locator('#air-model').input_value() == 'deepseek-chat')
        page.locator('#air-key').fill('fixture-private-only')
        page.locator('#air-save').click()
        page.wait_for_function('document.querySelector("#air-settings-status").textContent.includes("设置已保存")')
        check('key saved in password manager only', page.evaluate('fixtures.logins.length === 1 && !JSON.stringify([...fixtures.prefs]).includes("fixture-private-only")'))
        check('saved key field cleared', page.locator('#air-key').input_value() == '')
        check('other endpoint cannot reuse saved key', page.evaluate('!host.hasKey(location.origin + "/v1")'))
        page.locator('#air-removeKey').check(); page.locator('#air-save').click()
        page.wait_for_function('fixtures.logins.length === 0')
        check('credential deletion', page.evaluate('fixtures.logins.length === 0'))
        page.evaluate('host.stop()')
        check('shutdown cleans listeners, panels and bridge', page.evaluate('host.panels.size === 0 && fixtures.listeners.length === 0 && !Zotero.AIReader && !document.querySelector(".air-panel")'))
        check('no uncaught browser errors', not errors)
        browser.close()
      report = {'success': True, 'checks': checks, 'provider': 'local simulated OpenAI-compatible HTTP server', 'native_zotero_api': 'fixture adapter'}
      (ROOT / 'tests' / 'artifacts' / 'ui-smoke.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
      print(json.dumps(report, ensure_ascii=False, indent=2))
    finally: server.shutdown(); server.server_close()

if __name__ == '__main__': main()
