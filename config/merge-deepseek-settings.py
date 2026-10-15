#!/usr/bin/env python3
"""Merge the DeepSeek defaults into an existing pi settings.json.

Run as: merge-deepseek-settings.py <settings.json> <settings.deepseek.json>
Keeps the keys the user already has — their installed extensions live in
"packages" — and only adds what DeepSeek needs.
"""
import json
import sys

current, deepseek = sys.argv[1], sys.argv[2]
try:
    with open(current) as f:
        settings = json.load(f)
except (OSError, ValueError):
    settings = {}
with open(deepseek) as f:
    ds = json.load(f)

for key in ("defaultProvider", "defaultModel", "enabledModels"):
    settings[key] = ds[key]
packages = settings.setdefault("packages", [])
for pkg in ds["packages"]:
    if pkg not in packages:
        packages.append(pkg)

with open(current, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("✓ DeepSeek model config merged (existing extensions preserved)")
