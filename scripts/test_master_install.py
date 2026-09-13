"""Offline regression checks for the Master staging and rollback paths."""

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"


def shell_path(path):
    text = path.as_posix()
    return "/" + text[0].lower() + text[2:] if os.name == "nt" else text


class MasterInstall(unittest.TestCase):
    files = (
        "camoufox_session.py",
        "tunnel_manager.sh",
        "scheduler.sh",
        "tg_digest.sh",
    )

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="ips-master-test-"))
        self.secure = self.root / "secure"
        self.master = self.root / "master"
        self.payload = self.root / "payload"
        self.secure.mkdir()
        (self.master / "engine").mkdir(parents=True)
        self.payload.mkdir()
        (self.master / "tg_master.sh").write_text("old-core\n", encoding="utf-8")
        (self.master / "master.conf").write_text(
            'MASTER_VERSION="5.6.33"\nTG_TOKEN="test"\n', encoding="utf-8"
        )
        for name in self.files:
            (self.master / "engine" / name).write_text(
                f"old-{name}\n", encoding="utf-8"
            )
        (self.payload / "tg_master.sh").write_text(
            "#!/bin/bash\nprintf new-core\n", encoding="utf-8"
        )
        for name in self.files:
            (self.payload / name).write_text(f"new-{name}\n", encoding="utf-8")

    def tearDown(self):
        fixture_files = [
            self.secure / "MANIFEST.sha256",
            self.secure / "tg_master.sh",
            self.secure / "cron_master",
            self.secure / "MASTER_ROLLBACK_REQUIRED",
            self.secure / "master_rollback" / "tg_master.sh",
            self.secure / "master_rollback" / "master.conf",
            self.root / "urls",
            self.root / "events",
            self.root / "pip-called",
            self.master / "tg_master.sh",
            self.master / "master.conf",
            self.master / "tunnel_key",
            self.master / "data" / "timezones.json",
            self.master / "venv" / "bin" / "python3",
            self.master / "venv" / "bin" / "pip",
            self.payload / "tg_master.sh",
        ]
        for name in self.files:
            fixture_files.extend((
                self.master / "engine" / name,
                self.payload / name,
                self.secure / "master_rollback" / f"engine_{name}",
                self.secure / "master_rollback" / f"engine_{name}.missing",
            ))
        for path in fixture_files:
            path.unlink(missing_ok=True)
        for stage in self.secure.glob("engine_stage.*"):
            for name in self.files:
                (stage / name).unlink(missing_ok=True)
            stage.rmdir()
        for temp_file in (self.master / "data").glob(".timezones.*"):
            temp_file.unlink(missing_ok=True)
        for directory in (
            self.master / "venv" / "bin",
            self.master / "venv",
            self.master / "data",
            self.master / "profiles",
            self.master / "logs",
            self.master / "engine",
            self.master,
            self.secure / "master_rollback",
            self.secure,
            self.payload,
            self.root,
        ):
            if directory.exists():
                directory.rmdir()

    def write_manifest(self, missing=()):
        entries = []
        core = self.payload / "tg_master.sh"
        entries.append(f"{hashlib.sha256(core.read_bytes()).hexdigest()}  master/tg_master.sh")
        for name in self.files:
            if name in missing:
                continue
            path = self.payload / name
            entries.append(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  master/engine/{name}"
            )
        (self.secure / "MANIFEST.sha256").write_text("\n".join(entries) + "\n", encoding="utf-8")

    def prepare_working_venv(self):
        venv = self.master / "venv" / "bin"
        venv.mkdir(parents=True)
        python = venv / "python3"
        python.write_text(
            "#!/bin/bash\n"
            "if [[ \"$*\" == *installed_verstr* ]]; then printf '152.0.4-beta.30\\n'; fi\n",
            encoding="utf-8",
        )
        python.chmod(0o755)
        pip = venv / "pip"
        pip.write_text("#!/bin/bash\nprintf pip-called > \"$PIP_LOG\"\n", encoding="utf-8")
        pip.chmod(0o755)
        (self.master / "tunnel_key").write_text("key\n", encoding="utf-8")

    def q(self, path):
        return shlex.quote(shell_path(path))

    def prefix(self, fail_file=""):
        master_setup = ROOT / "install" / "master_setup.sh"
        engine_setup = ROOT / "install" / "engine_setup.sh"
        return textwrap.dedent(
            f"""
            SECURE_TMP={self.q(self.secure)}
            MASTER_DIR={self.q(self.master)}
            REPO_RAW_URL='https://repo.invalid/v5.6.34-fork'
            TARGET_VERSION='5.6.34'
            UPGRADE_MODE='true'
            KEEP_DB='true'
            PAYLOAD_DIR={self.q(self.payload)}
            URL_LOG={self.q(self.root / 'urls')}
            EVENT_LOG={self.q(self.root / 'events')}
            FAIL_FILE={shlex.quote(fail_file)}
            sleep() {{ :; }}
            is_systemd() {{ return 1; }}
            pkill() {{ printf 'stop\\n' >> "$EVENT_LOG"; return 0; }}
            pgrep() {{ return 0; }}
            nohup() {{ printf 'restart\\n' >> "$EVENT_LOG"; return 0; }}
            crontab() {{ return 0; }}
            apt-get() {{ return 1; }}
            curl() {{
                local output='' url='' arg name
                while [ "$#" -gt 0 ]; do
                    arg="$1"
                    shift
                    case "$arg" in
                        -o) output="$1"; shift ;;
                        http*) url="$arg" ;;
                    esac
                done
                printf '%s\\n' "$url" >> "$URL_LOG"
                case "$url" in
                    */master/tg_master.sh*) command cp "$PAYLOAD_DIR/tg_master.sh" "$output" ;;
                    */master/engine/*)
                        name="${{url##*/master/engine/}}"
                        name="${{name%%\\?*}}"
                        [ "$name" = "$FAIL_FILE" ] && return 22
                        command cp "$PAYLOAD_DIR/$name" "$output" ;;
                    */data/timezones.json*) printf '{{}}' > "$output" ;;
                    *) return 99 ;;
                esac
            }}
            source {self.q(master_setup)}
            source {self.q(engine_setup)}
            """
        )

    def run_shell(self, body, timeout=15):
        return subprocess.run(
            [BASH],
            cwd=ROOT,
            capture_output=True,
            text=True,
            input=body,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )

    def test_bootstrap_selects_only_ota_version_and_tag(self):
        source = (ROOT / "master" / "install_master.sh").read_text(encoding="utf-8")
        self.assertIn('TARGET_VERSION="${OTA_TARGET_VERSION:-}"', source)
        self.assertIn("REPO_RAW_URL=\"${REPO_MAIN_URL%/main}/v${TARGET_VERSION}-fork\"", source)
        self.assertIn("=~ ^[0-9]+[.][0-9]+[.][0-9]+$", source)
        self.assertNotIn('elif [ -n "${TARGET_VERSION:-}" ]', source)
        self.assertNotIn("is_valid_semver()", source)

    def test_staging_rejects_missing_hash_without_touching_live_files(self):
        self.write_manifest(missing=("scheduler.sh",))
        result = self.run_shell(
            self.prefix()
            + """
            if do_master_stage_payloads; then exit 10; fi
            test "$(command cat "$MASTER_DIR/tg_master.sh")" = old-core || exit 20
            command grep -Fqx 'MASTER_VERSION="5.6.33"' "$MASTER_DIR/master.conf" || exit 21
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(all(url.startswith("https://repo.invalid/v5.6.34-fork/")
                            for url in (self.root / "urls").read_text().splitlines()))

    def test_staging_rejects_missing_file_without_touching_live_files(self):
        self.write_manifest()
        result = self.run_shell(
            self.prefix(fail_file="scheduler.sh")
            + """
            if do_master_stage_payloads; then exit 10; fi
            test "$(command cat "$MASTER_DIR/tg_master.sh")" = old-core || exit 20
            test "$(command cat "$MASTER_DIR/engine/scheduler.sh")" = old-scheduler.sh || exit 21
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_success_deploys_engine_and_commits_version_after_restart(self):
        self.write_manifest()
        self.prepare_working_venv()
        result = self.run_shell(
            self.prefix()
            + f"PIP_LOG={self.q(self.root / 'pip-called')}\n"
            + """
            if ! do_master_stage_payloads; then exit 10; fi
            if ! do_master_deploy_core; then exit 11; fi
            if ! do_engine_setup; then exit 12; fi
            if ! do_master_finalize_version; then exit 13; fi
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.master / "tg_master.sh").read_text(), "#!/bin/bash\nprintf new-core\n")
        self.assertEqual((self.master / "engine" / "scheduler.sh").read_text(), "new-scheduler.sh\n")
        self.assertIn('MASTER_VERSION="5.6.34"', (self.master / "master.conf").read_text())
        self.assertNotIn('MASTER_VERSION="5.6.33"', (self.master / "master.conf").read_text())
        self.assertFalse((self.root / "pip-called").exists())
        urls = (self.root / "urls").read_text().splitlines()
        self.assertTrue(urls)
        self.assertTrue(all(url.startswith("https://repo.invalid/v5.6.34-fork/") for url in urls))

    def test_engine_move_failure_rolls_back_core_engine_and_version(self):
        self.write_manifest()
        self.prepare_working_venv()
        result = self.run_shell(
            self.prefix()
            + """
            if ! do_master_stage_payloads; then exit 10; fi
            if ! do_master_deploy_core; then exit 11; fi
            mv() {
                case "$*" in *scheduler.sh*) return 1 ;; *) command mv "$@" ;; esac
            }
            if do_engine_setup; then exit 12; fi
            if ! do_master_rollback; then exit 13; fi
            test "$(command cat "$MASTER_DIR/tg_master.sh")" = old-core || exit 20
            test "$(command cat "$MASTER_DIR/engine/camoufox_session.py")" = old-camoufox_session.py || exit 21
            test "$(command cat "$MASTER_DIR/engine/tunnel_manager.sh")" = old-tunnel_manager.sh || exit 22
            test "$(command cat "$MASTER_DIR/engine/scheduler.sh")" = old-scheduler.sh || exit 23
            test "$(command cat "$MASTER_DIR/engine/tg_digest.sh")" = old-tg_digest.sh || exit 24
            command grep -Fqx 'MASTER_VERSION="5.6.33"' "$MASTER_DIR/master.conf" || exit 25
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_finalize_service_failure_rolls_back_old_core_engine_and_version(self):
        self.write_manifest()
        self.prepare_working_venv()
        result = self.run_shell(
            self.prefix()
            + """
            if ! do_master_stage_payloads; then exit 10; fi
            if ! do_master_deploy_core; then exit 11; fi
            if ! do_engine_setup; then exit 12; fi
            is_systemd() { return 0; }
            SYSTEMCTL_PHASE=new
            systemctl() {
                printf 'systemctl %s\\n' "$*" >> "$EVENT_LOG"
                if [ "$SYSTEMCTL_PHASE" = new ] && [ "$1" = restart ]; then return 1; fi
                return 0
            }
            if do_master_finalize_version; then exit 13; fi
            SYSTEMCTL_PHASE=old
            if ! do_master_rollback; then exit 14; fi
            test "$(command cat "$MASTER_DIR/tg_master.sh")" = old-core || exit 20
            test "$(command cat "$MASTER_DIR/engine/camoufox_session.py")" = old-camoufox_session.py || exit 21
            test "$(command cat "$MASTER_DIR/engine/tunnel_manager.sh")" = old-tunnel_manager.sh || exit 22
            test "$(command cat "$MASTER_DIR/engine/scheduler.sh")" = old-scheduler.sh || exit 23
            test "$(command cat "$MASTER_DIR/engine/tg_digest.sh")" = old-tg_digest.sh || exit 24
            command grep -Fqx 'MASTER_VERSION="5.6.33"' "$MASTER_DIR/master.conf" || exit 25
            test ! -e "$SECURE_TMP/MASTER_ROLLBACK_REQUIRED" || exit 26
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_backup_failure_does_not_stop_existing_service(self):
        (self.secure / "tg_master.sh").write_text("#!/bin/bash\n", encoding="utf-8")
        result = self.run_shell(
            self.prefix()
            + """
            TMP_MASTER="$SECURE_TMP/tg_master.sh"
            do_master_save_rollback() { return 1; }
            if do_master_deploy_core; then exit 10; fi
            if ! do_master_rollback; then exit 11; fi
            test "$(command cat "$MASTER_DIR/tg_master.sh")" = old-core || exit 20
            test ! -e "$EVENT_LOG" || exit 21
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_mv_failure_restarts_old_service_even_without_swap(self):
        self.write_manifest()
        result = self.run_shell(
            self.prefix()
            + """
            TMP_MASTER="$SECURE_TMP/tg_master.sh"
            printf '#!/bin/bash\nprintf new-core\\n' > "$TMP_MASTER"
            mv() { return 1; }
            if do_master_deploy_core; then exit 10; fi
            if ! do_master_rollback; then exit 11; fi
            test "$(command cat "$MASTER_DIR/tg_master.sh")" = old-core || exit 20
            command grep -qx restart "$EVENT_LOG" || exit 21
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_restore_copy_failure_preserves_backup_and_does_not_restart_mixed_files(self):
        rollback = self.secure / "master_rollback"
        rollback.mkdir()
        (rollback / "tg_master.sh").write_text("old-core\n", encoding="utf-8")
        (rollback / "master.conf").write_text('MASTER_VERSION="5.6.33"\n', encoding="utf-8")
        (self.master / "tg_master.sh").write_text("new-core\n", encoding="utf-8")
        result = self.run_shell(
            self.prefix()
            + """
            MASTER_ROLLBACK_DIR="$SECURE_TMP/master_rollback"
            MASTER_ROLLBACK_CORE=true
            MASTER_ROLLBACK_CONFIG=true
            MASTER_SERVICE_STOPPED=true
            MASTER_SWAPPED=true
            cp() {
                if [ "$3" = "$MASTER_DIR/tg_master.sh" ] || [ "$3" = "$MASTER_DIR/master.conf" ]; then return 1; fi
                command cp "$@"
            }
            if do_master_rollback; then exit 10; fi
            test -f "$SECURE_TMP/MASTER_ROLLBACK_REQUIRED" || exit 20
            if [ -e "$EVENT_LOG" ]; then
                if command grep -qx restart "$EVENT_LOG"; then exit 21; fi
            fi
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
