#!/usr/bin/env python3
"""Build a reproducible Zotero XPI using Python's standard library only."""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile
import xml.etree.ElementTree as ET
from urllib.parse import urljoin, urlparse

ROOT = Path(__file__).resolve().parent

def build(destination):
    src = ROOT / 'src'
    manifest = json.loads((src / 'manifest.json').read_text())
    app = manifest['applications']['zotero']
    assert app['id'] == 'ai-reader@local.zotero'
    assert all(app.get(key) for key in ('id', 'update_url', 'strict_max_version')), 'Zotero requires id, update_url and strict_max_version'
    assert urlparse(app['update_url']).scheme == 'https', 'The public update manifest must use HTTPS'
    for path in src.rglob('*.xhtml'):
        ET.parse(path)
    files = sorted(p for p in src.rglob('*') if p.is_file())
    assert all(p.name == 'LICENSE' or p.suffix in ('.js', '.json', '.css', '.xhtml', '.ftl', '.svg') for p in files)
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / f'zotero-ai-reader-{manifest["version"]}.xpi'
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            entry = zipfile.ZipInfo(path.relative_to(src).as_posix(), (2026, 11, 2, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, path.read_bytes())
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None
        assert 'manifest.json' in archive.namelist() and 'bootstrap.js' in archive.namelist()
        assert all(not n.startswith('/') and '..' not in Path(n).parts for n in archive.namelist())
    checksum = hashlib.sha256(target.read_bytes()).hexdigest()
    updates = {'addons': {app['id']: {'updates': [{
        'version': manifest['version'],
        'update_link': urljoin(app['update_url'], 'dist/' + target.name),
        'update_hash': 'sha256:' + checksum,
        'applications': {'zotero': {key: app[key] for key in ('strict_min_version', 'strict_max_version')}}
    }]}}}
    (ROOT / 'updates.json').write_text(json.dumps(updates, ensure_ascii=False, indent=2) + '\n')
    (destination / 'updates.json').write_text(json.dumps(updates, ensure_ascii=False, indent=2) + '\n')
    (destination / 'SHA256SUMS.txt').write_text(f'{checksum}  {target.name}\n')
    print(json.dumps({'xpi': str(target), 'files': len(files), 'bytes': target.stat().st_size, 'sha256': checksum}, ensure_ascii=False))
    return target

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'dist')
    build(parser.parse_args().out)
