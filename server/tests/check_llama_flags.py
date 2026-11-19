"""Checks every option the server passes to llama-server exists in the pinned
llama.cpp build. An unknown option stops a model loading, so a release must
never ship one. Run in the release workflow (it needs the network)."""

import re
import sys
import urllib.request

sys.path.insert(0, "server")
sys.path.insert(0, ".")

from myna_server.engines import LLAMA_BUILD, runner_args  # noqa: E402

source = urllib.request.urlopen(
    f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{LLAMA_BUILD}/common/arg.cpp", timeout=60
).read().decode()
known = set(re.findall(r'"(-{1,2}[a-zA-Z][a-zA-Z0-9-]*)"', source))
used = set()
for device in ("gpu", "shared", "cpu"):
    for mtp in (False, True):
        used |= {arg for arg in runner_args(device, "/m.gguf", 8192, 8791, 8, mtp=mtp) if arg.startswith("-")}
missing = sorted(used - known)
if missing:
    sys.exit(f"llama-server {LLAMA_BUILD} does not know these options: {missing}")
print(f"All {len(used)} llama-server options exist in {LLAMA_BUILD}.")
