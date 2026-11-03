#!/usr/bin/env python3
"""Integration tests in a fresh, isolated Zotero profile with a local fake AI server."""
from pathlib import Path
import argparse
import json
import hashlib
import os
import shutil
import signal
import subprocess
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'tests' / 'artifacts'
ART.mkdir(exist_ok=True)

class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        text = data['messages'][-1]['content'].split('\n本轮问题：\n')[-1]
        if text == 'error401':
            self.send_response(401); self.send_header('Content-Type', 'application/json'); self.end_headers()
            self.wfile.write(json.dumps({'error': {'message': 'Invalid fixture-only-no-real-credential'}}).encode()); return
        answer = '测试回答：材料来自当前文献。\n**概念**：可核实的解释。\n<img src=x onerror=alert(1)>'
        if not data.get('stream'):
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
            self.wfile.write(json.dumps({'choices': [{'message': {'content': answer}, 'finish_reason': 'stop'}]}).encode()); return
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream; charset=utf-8'); self.end_headers()
        try:
            for part in [answer[i:i+5] for i in range(0, len(answer), 5)]:
                self.wfile.write(('data: ' + json.dumps({'choices': [{'delta': {'content': part}}]}, ensure_ascii=False) + '\n\n').encode()); self.wfile.flush()
                time.sleep(.12 if text == 'slow' else .005)
            self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass

def pdf_fixture(path):
    text = b'BT /F1 16 Tf 60 750 Td (Controlled reading experiment) Tj 0 -28 Td (Local integration fixture. No user library data.) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', b'<< /Length '+str(len(text)).encode()+b' >>\nstream\n'+text+b'\nendstream']
    body = bytearray(b'%PDF-1.4\n'); offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(body)); body += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    xref = len(body); body += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]: body += f'{offset:010d} 00000 n \n'.encode()
    body += f'trailer\n<< /Root 1 0 R /Size {len(offsets)} >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    path.write_bytes(body)

def main(version, binary):
    report = ART / ('runtime-' + version + '.json')
    report.unlink(missing_ok=True)
    profile = ROOT / 'tests' / ('profile-' + version)
    if profile.exists(): shutil.rmtree(profile)
    extensions = profile / 'extensions'; extensions.mkdir(parents=True)
    data_dir = profile / 'zotero-data'; data_dir.mkdir()
    prefs = {'extensions.autoDisableScopes': 0, 'extensions.enabledScopes': 15,
        'extensions.logging.enabled': True,
        'extensions.zotero.dataDir': str(data_dir), 'extensions.zotero.useDataDir': True,
        'extensions.zotero.firstRun2': False, 'extensions.zotero.automaticScraperUpdates': False,
        'extensions.zotero.autoSync': False, 'extensions.zotero.reportTranslationFailure': False,
        'extensions.zotero.repository.lastCheck.localTime': 2147483647,
        'app.update.enabled': False, 'app.update.auto': False, 'browser.shell.checkDefaultBrowser': False}
    (profile / 'user.js').write_text('\n'.join(f'user_pref({json.dumps(k)}, {json.dumps(v)});' for k,v in prefs.items()))
    package_manifest = json.loads((ROOT / 'src' / 'manifest.json').read_text())
    package_version = package_manifest['version']
    # The driver installs the release through AddonManager, exercising the real install path.
    manifest = {'manifest_version': 2, 'name': 'AI Reader integration driver', 'version': '1.0',
        'applications': {'zotero': {'id': 'zzz-ai-reader-driver@local.test', 'update_url': 'https://example.invalid/ai-reader-test-updates.json', 'strict_min_version': '7.0', 'strict_max_version': package_manifest['applications']['zotero']['strict_max_version']}}}
    with zipfile.ZipFile(extensions / 'zzz-ai-reader-driver@local.test.xpi', 'w') as z:
        z.writestr('manifest.json', json.dumps(manifest)); z.write(ROOT / 'tests' / 'runtime-driver.js', 'bootstrap.js')
    pdf_fixture(ROOT / 'tests' / 'fixture.pdf')
    server = ThreadingHTTPServer(('127.0.0.1', 18761), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    cache = ROOT / 'runtime' / 'cache'; cache.mkdir(exist_ok=True)
    env = dict(os.environ, MOZ_CRASHREPORTER_DISABLE='1', MOZ_DISABLE_CONTENT_SANDBOX='1',
        MOZ_DISABLE_RDD_SANDBOX='1', MOZ_DISABLE_GMP_SANDBOX='1', MOZ_DISABLE_GPU_SANDBOX='1',
        XDG_CACHE_HOME=str(cache), DISPLAY=':98', LIBGL_ALWAYS_SOFTWARE='1',
        LD_LIBRARY_PATH=str(ROOT / 'runtime' / 'deps' / 'usr' / 'lib' / 'x86_64-linux-gnu'))
    env.pop('MOZ_HEADLESS', None)
    xvfb_log = (ART / 'xvfb.log').open('w')
    Path('/tmp/.X11-unix').mkdir(mode=0o1777, exist_ok=True)
    display = subprocess.Popen([str(ROOT / 'runtime' / 'deps' / 'usr' / 'bin' / 'Xvfb'), ':98', '-ac', '-screen', '0', '1280x900x24', '-nolisten', 'tcp'], env=env, stdout=xvfb_log, stderr=subprocess.STDOUT)
    time.sleep(.5)
    output = ART / f'zotero-{version}.log'
    with output.open('w') as log:
        proc = subprocess.Popen([str(binary), '-no-remote', '-profile', str(profile), '-ZoteroDebugText'], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try: proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            try:
                from PIL import ImageGrab
                ImageGrab.grab(xdisplay=':98').save(ART / ('screen-' + version + '.png'))
            except Exception as e: print('Diagnostic screenshot:', type(e).__name__, flush=True)
        try: code = proc.wait(timeout=100)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(proc.pid, signal.SIGKILL); proc.wait()
            display.terminate(); display.wait(); xvfb_log.close()
            print(json.dumps({'version': version, 'success': False, 'reason': 'runtime timed out', 'log': str(output)}), flush=True); return 1
    server.shutdown()
    display.terminate(); display.wait(); xvfb_log.close()
    if report.exists():
        result = json.loads(report.read_text())
        result['zotero_version'] = version
        result['platform'] = 'Linux container, official Zotero desktop runtime'
        result['plugin_version'] = package_version
        result['xpi_sha256'] = hashlib.sha256((ROOT / 'dist' / f'zotero-ai-reader-{package_version}.xpi').read_bytes()).hexdigest()
        report.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        return 0 if result['success'] else 1
    print(json.dumps({'version': version, 'success': False, 'exit_code': code, 'log': str(output)}), flush=True); return 1

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('version'); parser.add_argument('binary', type=Path)
    args = parser.parse_args(); raise SystemExit(main(args.version, args.binary.resolve()))
