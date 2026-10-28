#!/usr/bin/env python3
"""Generate real USTAR inputs, including hostile entries, for installer checks."""
import importlib.util
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("runtime_package", Path(__file__).with_name("package-agent-runtime.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
root = Path(sys.argv[1])
payload = root / "source"
payload.mkdir()
subprocess.run(["/usr/bin/clang", "-x", "c", "-", "-o", str(payload / "pi-work-agent-host")],
               input=b"int main(void) { return 0; }\n", check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(payload / "pi-work-agent-host")],
               check=True, capture_output=True)
(payload / "pi-work-agent-host").chmod(0o755)
shutil.copyfile(payload / "pi-work-agent-host", payload / "bun")
(payload / "bun").chmod(0o755)
for name in ["theme/theme.json", "export-html/template.html"]:
    path = payload / name
    path.parent.mkdir(exist_ok=True)
    path.write_text("runtime test resource\n")
metadata = json.loads((Path(__file__).resolve().parents[1] / "AgentHost/package.json").read_text())
metadata["piWorkRuntime"]["version"] = "1.1.0"
architecture = "arm64" if __import__("platform").machine() == "arm64" else "x86_64"
packager.package(payload, metadata, architecture, root)

# A native signed host lets the Swift checks exercise real process recovery,
# rather than replacing the service's launch or integrity implementations.
fixture_payload = root / "fixture-source"
shutil.copytree(payload, fixture_payload)
metadata["piWorkRuntime"]["version"] = "1.2.0"
protocol = (Path(__file__).resolve().parents[1] / "AgentHost/src/acp-protocol.ts").read_text()
capabilities = re.findall(r'"([^"]+)"', protocol.split("PI_WORK_CAPABILITIES = [", 1)[1].split("] as const", 1)[0])
pi_version = metadata["dependencies"]["@earendil-works/pi-coding-agent"]
initialize = json.dumps({"jsonrpc": "2.0", "id": "__pi_work_initialize__", "result": {
    "protocolVersion": 1, "agentInfo": {"name": "runtime-fixture", "version": "fixture"},
    "agentCapabilities": {"promptCapabilities": {"image": True},
                          "sessionCapabilities": {"list": {}, "resume": {}, "close": {}}},
    "_meta": {"piVersion": pi_version, "piWork": {"extensions": True, "capabilities": capabilities,
             "runtime": {"version": "1.2.0", "apiVersion": 1, "piVersion": pi_version}}}}})
settings = json.dumps({"defaultThinkingLevel": "off", "transport": "auto", "compactionEnabled": True, "retryEnabled": True})
c_source = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  if (getenv("PI_WORK_PROBE_LEAK_TEST")) return 11;
  char line[65536];
  while (fgets(line, sizeof(line), stdin)) {
    if (strstr(line, "\"initialize\"")) { puts(INITIALIZE); fflush(stdout); continue; }
    int models = strstr(line, "models") != NULL;
    if (models && getenv("PI_WORK_TEST_CRASH")) return 7;
    char *id = strstr(line, "\"id\"");
    if (!id || !(id = strchr(id, ':'))) return 8;
    while (*++id == ' ') {}
    char *end = strchr(id + 1, '"');
    if (!end) return 9;
    printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":%s}\n", (int)(end - id + 1), id, models ? "{\"models\":[]}" : SETTINGS);
    fflush(stdout);
  }
  return 0;
}
'''
source = root / "fixture.c"
source.write_text("#define INITIALIZE " + json.dumps(initialize) + "\n#define SETTINGS " + json.dumps(settings) + "\n" + c_source)
fixture_host = fixture_payload / "pi-work-agent-host"
subprocess.run(["/usr/bin/clang", str(source), "-o", str(fixture_host)], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(fixture_host)], check=True, capture_output=True)
packager.package(fixture_payload, metadata, architecture, root / "fixture-release")

for kind in ["traversal", "symlink", "hardlink", "duplicate", "oversized", "absolute", "reserved"]:
    with tarfile.open(root / f"{kind}.tar.gz", "w:gz", format=tarfile.USTAR_FORMAT) as tar:
        entry = tarfile.TarInfo({"traversal": "../escaped", "absolute": "/tmp/escaped",
                                 "reserved": "installed.json"}.get(kind, "pi-work-agent-host"))
        if kind in ["symlink", "hardlink"]:
            entry.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
            entry.linkname = "/tmp/outside"
        if kind == "oversized":
            entry.size = 1024 * 1024 * 1024
            tar.fileobj.write(entry.tobuf(format=tarfile.USTAR_FORMAT))
        else:
            entry.size = 1 if kind == "duplicate" else 0
            tar.addfile(entry, io.BytesIO(b"a"))
            if kind == "duplicate":
                tar.addfile(entry, io.BytesIO(b"a"))
