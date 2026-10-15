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
except FileNotFoundError:
    settings = {}   # fresh volume; invalid JSON must still stop the script, not wipe the file
with open(deepseek) as f:
    ds = json.load(f)

for key in ("defaultProvider", "defaultModel"):
    settings[key] = ds[key]
for key in ("enabledModels", "packages"):
    merged = settings.setdefault(key, [])
    merged.extend(x for x in ds[key] if x not in merged)

with open(current, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("✓ DeepSeek model config merged (existing extensions preserved)")
