#!/usr/bin/env python3
"""Exercise the native MLX process and packaged CLI boundary on Apple silicon."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

helper = Path(sys.argv[1]).resolve()
cli = Path(sys.argv[2]).resolve()

def call(*arguments):
    process = subprocess.run([str(helper), *arguments], capture_output=True, text=True, check=True, timeout=180)
    return json.loads(process.stdout)

for arguments in [[], ["{"], [json.dumps({"model": "", "messages": [{}]})],
                  [json.dumps({"model": "unused", "messages": []})],
                  [json.dumps({"model": "/nonexistent-sidepulse-fixture", "messages": [{"role": "user", "content": "test"}]})]]:
    assert "error" in call(*arguments), arguments

with tempfile.TemporaryDirectory(prefix="sidepulse-classifier-test-") as folder:
    stage = Path(folder)
    shutil.copy2(cli, stage / "sidepulsectl")
    shutil.copy2(helper, stage / "sidepulse-classifier")
    for resource in helper.parent.glob("*.bundle"):
        shutil.copytree(resource, stage / resource.name)
    shutil.copy2(helper.parent / "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib", stage / "mlx.metallib")
    # Captured from the original Python classifier using these exact model weights.
    # This checks port compatibility, not general language-model accuracy.
    reference = {"Are you available tomorrow?": "0", "The build finished successfully.": "0",
                 "Thanks!": "0", "Please approve the draft.": "1"}
    for message, expected in reference.items():
        result = subprocess.run([str(stage / "sidepulsectl"), "classify", "--backend", "mlx", "--json", message],
                                capture_output=True, text=True, check=True, timeout=180)
        classification = json.loads(result.stdout)
        assert classification["label"] in {"REPLY_REQUIRED", "NO_REPLY_REQUIRED", "UNCERTAIN"}
        assert classification["raw_output"].strip() == expected, classification
        plain = subprocess.run([str(stage / "sidepulsectl"), "classify", "--backend", "mlx", message],
                               capture_output=True, text=True, check=True, timeout=180)
        assert plain.stdout.strip() == classification["label"], plain.stdout
        print(message, classification)
print("Native MLX helper and CLI integration passed")
