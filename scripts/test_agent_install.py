"""Offline checks of real Agent staging, handoff and version-commit blocks."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"
SOURCE = (ROOT / "core/install.sh").read_text(encoding="utf-8")
CORE_FILES = ("updater.sh", "tg_report.sh", "agent_daemon.sh", "uninstall.sh", "mod_quality.sh")


def section(start, end):
    return SOURCE[SOURCE.index(start):SOURCE.index(end)]


def shell_path(path):
    value = path.as_posix()
    return "/" + value[0].lower() + value[2:] if os.name == "nt" else value


class AgentInstall(unittest.TestCase):
    def test_pinned_version_does_not_requery_main(self):
        version = section('REPO_RAW_URL="https://', '\nversion_lt()')
        script = ('curl() { echo UNEXPECTED_NETWORK >&2; return 99; }\n'
                  'OTA_TARGET_VERSION=5.6.34\n' + version
                  + '\nprintf "%s|%s" "$TARGET_VERSION" "$REPO_RAW_URL"\n')
        result = subprocess.run([BASH], input=script, capture_output=True,
                                text=True, encoding="utf-8", timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("UNEXPECTED_NETWORK", result.stderr)
        self.assertTrue(result.stdout.endswith("5.6.34|https://raw.githubusercontent.com/jasper-khan/IP-Sentinel/v5.6.34-agent"))

    def test_staging_and_recovery(self):
        stages = section('INSTALL_STAGE=$(mktemp', '# [身份连续性]')
        handoff = section('echo "⏳ 五个核心模块', '# [残留清扫]')
        complete = section('# [完成门禁]', '# [通讯指控]')
        payload = b"#!/bin/bash\n: NEW\n"
        digest = hashlib.sha256(payload).hexdigest()
        manifest = "".join(f"{digest}  core/{f}\n" for f in CORE_FILES)
        manifest += f"{digest}  data/probe/ip.sh\n"
        config = 'AGENT_VERSION="5.6.33"\n'
        for scenario in ("core_failure", "probe_failure", "probe_hash", "move_failure", "startup_failure", "success"):
            with self.subTest(scenario=scenario):
                root = Path(tempfile.mkdtemp(prefix="ips-install-test-"))
                folders = ("live", "live/core", "live/data", "live/data/probe", "tmp")
                for folder in folders:
                    (root / folder).mkdir()
                for f in CORE_FILES:
                    (root / "live/core" / f).write_text("OLD", encoding="utf-8")
                (root / "live/data/probe/ip.sh").write_text("OLD_PROBE", encoding="utf-8")
                (root / "live/data/probe/ip.sh.sha256").write_text("OLD_HASH", encoding="utf-8")
                (root / "live/config.conf").write_text(config, encoding="utf-8")
                (root / "tmp/config.before").write_text(config, encoding="utf-8")
                (root / "payload").write_bytes(payload)
                (root / "manifest").write_text(manifest, encoding="utf-8", newline="\n")
                mocks = r'''
INSTALL_DIR="$TEST_ROOT/live"
SECURE_TMP="$TEST_ROOT/tmp"
CONFIG_FILE="$INSTALL_DIR/config.conf"
TARGET_VERSION=5.6.34
REPO_RAW_URL=https://audit.invalid/v5.6.34-agent
UPGRADE_MODE=true
TG_TOKEN=audit
CHAT_ID=audit
AGENT_PORT=1
is_systemd() { return 0; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_ROOT/actions"; }
pkill() { printf 'pkill\n' >> "$TEST_ROOT/actions"; }
crontab() { return 0; }
sleep() { :; }
# Fixture cleanup is explicit in Python below, never delegated to rm -rf.
rm() { :; }
mktemp() { mkdir "$TEST_ROOT/stage"; printf '%s\n' "$TEST_ROOT/stage"; }
python3() { cat >/dev/null; [ "$SCENARIO" != startup_failure ]; }
mv() {
    if [ "$SCENARIO" = move_failure ] && [ "$1" = "$TEST_ROOT/stage/core" ]; then return 1; fi
    command mv "$@"
}
curl() {
    local url= out=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o) shift; out="$1" ;;
            https://*) url="$1" ;;
        esac
        shift
    done
    case "$url" in https://audit.invalid/v5.6.34-agent/*) ;; *) echo UNEXPECTED_NETWORK >&2; return 99 ;; esac
    case "${url%%\?*}" in
        */MANIFEST.sha256) command cp "$TEST_ROOT/manifest" "$out" ;;
        */data/probe/ip.sh)
            [ "$SCENARIO" = probe_failure ] && return 22
            if [ "$SCENARIO" = probe_hash ]; then printf BAD > "$out"
            else command cp "$TEST_ROOT/payload" "$out"; fi ;;
        */core/*.sh)
            [ "$SCENARIO" = core_failure ] && return 22
            command cp "$TEST_ROOT/payload" "$out" ;;
        *) echo UNEXPECTED_NETWORK >&2; return 99 ;;
    esac
}
'''
                script = ("TEST_ROOT=" + shlex.quote(shell_path(root)) + "\nSCENARIO=" + scenario
                          + "\n" + mocks + stages + handoff + complete)
                try:
                    result = subprocess.run([BASH], input=script, capture_output=True,
                                            text=True, encoding="utf-8", timeout=15)
                    self.assertNotIn("UNEXPECTED_NETWORK", result.stderr)
                    expected_core = payload if scenario == "success" else b"OLD"
                    self.assertEqual((root / "live/core/agent_daemon.sh").read_bytes(), expected_core, result.stdout + result.stderr)
                    expected_probe = payload if scenario == "success" else b"OLD_PROBE"
                    self.assertEqual((root / "live/data/probe/ip.sh").read_bytes(), expected_probe)
                    self.assertIn('5.6.34' if scenario == "success" else '5.6.33',
                                  (root / "live/config.conf").read_text(encoding="utf-8"))
                    self.assertEqual(result.returncode == 0, scenario == "success", result.stdout + result.stderr)
                    if scenario in ("core_failure", "probe_failure", "probe_hash"):
                        self.assertFalse((root / "actions").exists(), "download failure stopped old services")
                    elif scenario != "success":
                        self.assertIn("restart ip-sentinel-agent-daemon.service", (root / "actions").read_text())
                    print("PASS", scenario)
                finally:
                    # Only fixed, known fixture names. No recursive deletion.
                    for folder in ("live/core", "stage/core", "stage/old_core", "stage/failed_core"):
                        for f in CORE_FILES:
                            (root / folder / f).unlink(missing_ok=True)
                    for folder in ("live/data/probe", "stage/probe", "stage/old_probe", "stage/failed_probe"):
                        (root / folder / "ip.sh").unlink(missing_ok=True)
                        (root / folder / "ip.sh.sha256").unlink(missing_ok=True)
                    for f in ("payload", "manifest", "actions", "live/config.conf", "tmp/config.before", "tmp/cron.before", "tmp/MANIFEST.sha256"):
                        (root / f).unlink(missing_ok=True)
                    for folder in ("live/core", "live/data/probe", "live/data", "live", "stage/core", "stage/probe", "stage/old_core", "stage/old_probe", "stage/failed_core", "stage/failed_probe", "stage", "tmp"):
                        if (root / folder).exists():
                            (root / folder).rmdir()
                    root.rmdir()


if __name__ == "__main__":
    unittest.main()
