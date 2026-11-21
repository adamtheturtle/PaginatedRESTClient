"""Refresh the vendored Vale AI Tells archive tracked by Renovate."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / ".vale.ini"
STYLES = ROOT / "vale" / "styles"
REPOSITORY = "tbhb/vale-ai-tells"
VERSION = r"v\d+\.\d+\.\d+"
ARCHIVE = re.compile(
    rf"^# (https://github\.com/{REPOSITORY}/releases/download/({VERSION})/ai-tells\.zip)$",
    re.MULTILINE,
)
VENDORED = re.compile(rf"(?m)^# Vale AI Tells ({VERSION}) is vendored")
DIGEST = re.compile(r"(?m)^# ai-tells\.zip SHA-256: [a-f0-9]{64}$")
RULE_PREFIX = ("ai-tells", "styles", "ai-tells")
TEMPLATE_PATH = "config/templates/ai-tells-agent.tmpl"


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "PaginatedRESTClient Vale vendor"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def read_styles(archive):
    rules = {}
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        for entry in package.infolist():
            if entry.is_dir():
                continue
            path = PurePosixPath(entry.filename)
            if path.parts == ("ai-tells", "styles", *TEMPLATE_PATH.split("/")):
                name = TEMPLATE_PATH
            elif (
                len(path.parts) == 4
                and path.parts[:3] == RULE_PREFIX
                and re.fullmatch(r"[A-Za-z0-9_-]+\.yml", path.name)
            ):
                name = f"ai-tells/{path.name}"
            else:
                raise ValueError(f"Unexpected archive member: {entry.filename}")
            if name in rules:
                raise ValueError(f"Duplicate archive member: {entry.filename}")
            rules[name] = package.read(entry)
    if len(rules) < 2 or TEMPLATE_PATH not in rules:
        raise ValueError("The archive must contain the Vale rules and the agent template")
    return rules


def refresh(config, url, version):
    release = json.loads(download(f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{version}"))
    asset = next(
        (asset for asset in release["assets"] if asset["browser_download_url"] == url),
        None,
    )
    digest = asset.get("digest") if asset else None
    if not digest or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise ValueError(f"The release does not publish a SHA-256 digest for {url}")

    archive = download(url)
    checksum = hashlib.sha256(archive).hexdigest()
    if digest != f"sha256:{checksum}":
        raise ValueError("The Vale archive does not match the published SHA-256 digest")
    files = read_styles(archive)

    config = VENDORED.sub(f"# Vale AI Tells {version} is vendored", config)
    config = DIGEST.sub(f"# ai-tells.zip SHA-256: {checksum}", config)
    with tempfile.TemporaryDirectory(dir=ROOT) as directory:
        stage = Path(directory)
        for name, content in files.items():
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        staged_config = stage / CONFIG.name
        staged_config.write_text(config, encoding="utf-8")

        replacements = [
            (stage / "ai-tells", STYLES / "ai-tells"),
            (stage / TEMPLATE_PATH, STYLES / TEMPLATE_PATH),
            (staged_config, CONFIG),
        ]
        installed = []
        try:
            for source, target in replacements:
                backup = stage / f"backup-{target.name}"
                target.replace(backup)
                installed.append((source, target, backup))
                source.replace(target)
        except OSError:
            for source, target, backup in reversed(installed):
                if target.exists():
                    target.replace(source)
                backup.replace(target)
            raise
    print(f"Vendored Vale AI Tells {version} (SHA-256 {checksum})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check the version without downloading the archive")
    args = parser.parse_args()
    config = CONFIG.read_text(encoding="utf-8")
    archive = ARCHIVE.search(config)
    vendored = VENDORED.search(config)
    if not archive or not vendored or not DIGEST.search(config):
        parser.error("Expected a release URL, vendored version, and SHA-256 digest in .vale.ini")
    url, version = archive.groups()
    if args.check:
        if vendored.group(1) != version:
            parser.error("Run python3 scripts/vendor_vale_ai_tells.py to refresh the vendored release")
        return
    refresh(config, url, version)


if __name__ == "__main__":
    main()
