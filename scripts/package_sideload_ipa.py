#!/usr/bin/env python3
"""Package an unsigned SIDELOAD device build without changing the build product."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import zipfile


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ValueError(f"Invalid iOS version: {value!r}")
    return tuple((list(map(int, value.split("."))) + [0])[:3])


def device_minimum_os(executable):
    with executable.open("rb") as handle:
        header = handle.read(32)
        if len(header) != 32:
            raise ValueError("Missing Mach-O executable header")
        magic, cpu, _, _, commands, command_bytes, _, _ = struct.unpack("<8I", header)
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise ValueError("Expected a thin arm64 device executable")
        if command_bytes > 16 * 1024 * 1024:
            raise ValueError("Invalid Mach-O load command size")
        data = handle.read(command_bytes)
    offset = 0
    for _ in range(commands):
        if offset + 8 > len(data):
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command == 0x32 and size >= 24:
            platform, minimum = struct.unpack_from("<2I", data, offset + 8)
            if platform != 2:
                raise ValueError("The executable is not built for physical iOS devices")
            return (minimum >> 16, (minimum >> 8) & 255, minimum & 255)
        offset += size
    raise ValueError("Missing iOS LC_BUILD_VERSION load command")


def package_app(app, output, bundle_id, compatible_ios, commit=""):
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("Input must be an Xcode-built .app directory")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("Invalid bundle identifier")
    if bundle_id == "org.zotero.ios.Zotero":
        raise ValueError("Use an independent bundle identifier for the sideload app")
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    name = info.get("CFBundleExecutable", "")
    if not name or Path(name).name != name:
        raise ValueError("Invalid bundle executable name")
    minimum = device_minimum_os(app / name)
    target = version(compatible_ios)
    if minimum > target or version(info["MinimumOSVersion"]) > target:
        raise ValueError("The build requires an iOS version newer than the target device")

    info["CFBundleIdentifier"] = bundle_id
    info["CFBundleDisplayName"] = "Zotero Translate"
    info["ZoteroSideloadBuild"] = True
    patched_info = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".partial")
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(app.rglob("*")):
                relative = path.relative_to(app)
                if relative.parts[0] == "PlugIns" or "_CodeSignature" in relative.parts:
                    continue
                if path.name == "embedded.mobileprovision":
                    continue
                archive_name = "Payload/" + app.name + "/" + relative.as_posix()
                metadata = zipfile.ZipInfo.from_file(path, archive_name)
                metadata.compress_type = zipfile.ZIP_DEFLATED
                if path.is_symlink():
                    if not path.resolve().is_relative_to(app.resolve()):
                        raise ValueError("Bundle symlink escapes the application directory")
                    metadata.create_system = 3
                    metadata.filename = archive_name
                    metadata.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(metadata, os.readlink(path).encode())
                elif relative.as_posix() == "Info.plist":
                    archive.writestr(metadata, patched_info)
                elif path.is_file():
                    archive.write(path, archive_name)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA integrity verification failed")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)

    digest = hashlib.sha256()
    with output.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    manifest = {
        "file": output.name,
        "sha256": digest.hexdigest(),
        "source_commit": commit,
        "bundle_identifier": bundle_id,
        "architecture": "arm64",
        "platform": "iPhoneOS",
        "minimum_ios": ".".join(map(str, minimum)),
        "target_ios": compatible_ios,
        "signature": "unsigned; sign on Windows before installation",
        "storage": "private application sandbox and keychain (SIDELOAD build)",
        "excluded": ["share extension", "App Group and iCloud entitlements"],
        "physical_device_tested": False,
    }
    output.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--bundle-id", default="org.meltaltoria.ZoteroTranslate")
    parser.add_argument("--target-ios", default="18.7.8")
    parser.add_argument("--commit", default="")
    args = parser.parse_args()
    print(json.dumps(package_app(args.app, args.output, args.bundle_id, args.target_ios, args.commit), indent=2))
