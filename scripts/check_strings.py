#!/usr/bin/env python3
"""Fails when a string passed to L.string / L.format has no Ukrainian translation, or a translation is unused."""
import glob
import json
import re
import subprocess
import sys

used = set()
for path in glob.glob("Sources/Tapetum/*.swift"):
    for m in re.finditer(r'L\.(?:string|format)\(\s*"((?:[^"\\]|\\.)*)"', open(path, encoding="utf-8").read()):
        used.add(m.group(1))

plist = subprocess.run(["plutil", "-convert", "json", "-o", "-", "Resources/uk.lproj/Localizable.strings"],
                       capture_output=True, text=True, check=True).stdout
translated = set(json.loads(plist))

missing, unused = sorted(used - translated), sorted(translated - used)
for key in missing:
    print(f"missing in uk.lproj: {key}")
for key in unused:
    print(f"unused in uk.lproj: {key}")
print(f"{len(used)} strings, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing or unused else 0)
