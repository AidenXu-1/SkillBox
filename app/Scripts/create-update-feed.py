#!/usr/bin/env python3
"""Prepare signed Sparkle artifacts locally, without publishing or exporting keys."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import subprocess
from urllib.parse import quote, urlparse
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def create_feed(bundle, archive, base_url, output, notes, account):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.zhaoji.skillbox':
        raise ValueError('Only SkillBox application updates are supported')
    if urlparse(base_url).scheme != 'https':
        raise ValueError('Public update downloads must use HTTPS')
    app_root = Path(__file__).resolve().parents[1]
    signer = app_root / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    public_key = subprocess.check_output([str(signer.parent / 'generate_keys'), '--account', account, '-p'], text=True).strip()
    if public_key != info.get('SUPublicEDKey'):
        raise ValueError('Signing key does not match the application public key')
    signature = subprocess.check_output([str(signer), '--account', account, '-p', str(archive)], text=True).strip()
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'SkillBox Updates'
    ET.SubElement(channel, 'link').text = 'https://github.com/AidenXu-1/SkillBox'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'SkillBox ' + info['CFBundleShortVersionString']
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = info['CFBundleVersion']
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = info['CFBundleShortVersionString']
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'description', {f'{{{SPARKLE}}}format': 'plain-text'}).text = notes
    ET.SubElement(item, 'enclosure', {
        'url': base_url.rstrip('/') + '/' + quote(archive.name),
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(rss)
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(rss).write(output, encoding='utf-8', xml_declaration=True)
    subprocess.run([str(signer), '--account', account, str(output)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([str(signer), '--account', account, '--verify', str(archive), signature], check=True)
    subprocess.run([str(signer), '--account', account, '--verify', str(output)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--account', default='com.zhaoji.skillbox')
    args = parser.parse_args()
    create_feed(args.app, args.archive, args.base_url, args.output, args.notes.read_text(), args.account)
