"""Offline regression checks for the master control paths."""

import ast
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MASTER_SOURCE = ROOT / "master" / "tg_master.sh"
ENGINE_SOURCE = ROOT / "master" / "engine" / "camoufox_session.py"
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"
if BASH and not Path(BASH).exists():
    BASH = None


def source_arm(source, marker, next_marker):
    start = source.index(marker)
    end = source.index(next_marker, start)
    return source[start:end]


def shell_path(path):
    text = Path(path).as_posix()
    return "/" + text[0].lower() + text[2:] if os.name == "nt" else text


def run_bash(script):
    if not BASH:
        raise unittest.SkipTest("bash is unavailable; shell regression checks skipped")
    return subprocess.run([BASH], input=script, capture_output=True, text=True,
                          encoding="utf-8", timeout=15)


def run_case(arm, text, response):
    return run_bash(
        """
set +e
CHAT_ID=123
MSG_ID=
TEXT=%s
MOCK_RESPONSE=%s
db_exec() { printf '198.51.100.1|443\\n'; }
call_agent() { printf '%%s\\n' "$MOCK_RESPONSE"; }
render_msg() { :; }
send_msg() { printf 'SENT:%%s\\n' "$2"; }
case "$TEXT" in
%s
esac
""" % (shlex.quote(text), shlex.quote(response), arm)
    )


def load_engine():
    spec = importlib.util.spec_from_file_location("camoufox_session_under_test", ENGINE_SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MasterControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.master = MASTER_SOURCE.read_text(encoding="utf-8")
        cls.engine = load_engine()

    def test_python_source_has_region_verdict(self):
        tree = ast.parse(ENGINE_SOURCE.read_text(encoding="utf-8"))
        self.assertTrue(any(isinstance(node, ast.FunctionDef) and node.name == "region_verdict"
                            for node in ast.walk(tree)))

    def test_ui_json_is_safe_and_preserves_intended_line_breaks(self):
        """The jq substitute checks argument/payload handoff only; real jq execution is Linux-only."""
        send_ui = source_arm(self.master, "send_ui() {", "\nsend_msg()")
        render_ui = source_arm(self.master, "render_ui() {", "\n# [核心重构] 文本沉底重绘引擎")
        message = 'first\\n"quoted" \\\\server\\path\nlast'
        chat_id = 'chat"1'
        buttons = '[[{"text":"say \\"hi\\"","callback_data":"keep"}]]'

        directory = tempfile.mkdtemp(prefix="ips-master-controls-")
        capture = Path(directory) / "payloads"
        try:
            shell = r'''
set -u
MASTER_DIR=%s
TG_TOKEN=test
CAPTURE=%s
jq() {
    local chat_id="" text="" inline_keyboard="" expression="" arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            --arg|--argjson)
                case "$1" in
                    chat_id) chat_id="$2" ;;
                    text) text="$2" ;;
                    inline_keyboard) inline_keyboard="$2" ;;
                esac
                shift 2
                ;;
            *) expression="$arg" ;;
        esac
    done
    JQ_CHAT_ID="$chat_id" JQ_TEXT="$text" JQ_INLINE_KEYBOARD="$inline_keyboard" \
        JQ_EXPRESSION="$expression" python - <<'PY'
import os
import json

if ".result.message_id" in os.environ["JQ_EXPRESSION"]:
    print("42")
else:
    text = os.environ["JQ_TEXT"].replace("\\n", "\n")
    body = {
        "chat_id": os.environ["JQ_CHAT_ID"],
        "text": text,
        "parse_mode": "Markdown",
        "reply_markup": {"inline_keyboard": json.loads(os.environ["JQ_INLINE_KEYBOARD"])},
    }
    print(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
PY
}
curl() {
    local body="" url="" arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            -d) body="$1"; shift ;;
            http://*|https://*) url="$arg" ;;
        esac
    done
    case "$url" in
        *sendMessage)
            printf '%%s\n' "$body" >> "$CAPTURE"
            printf '{"ok":true,"result":{"message_id":42}}'
            ;;
        *) printf '{"ok":true}' ;;
    esac
}
''' % (shlex.quote(shell_path(directory)), shlex.quote(shell_path(capture)))
            shell += send_ui + "\n" + render_ui + "\n"
            shell += "send_ui %s %s %s\n" % (
                shlex.quote(chat_id), shlex.quote(message), shlex.quote(buttons))
            shell += "render_ui %s '' %s %s\n" % (
                shlex.quote(chat_id), shlex.quote(message), shlex.quote(buttons))
            result = run_bash(shell)
            self.assertEqual(result.returncode, 0, result.stderr)

            payloads = [json.loads(line) for line in capture.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(payloads), 2)
            expected_markup = {"inline_keyboard": json.loads(buttons)}
            for payload in payloads:
                self.assertEqual(payload["chat_id"], chat_id)
                self.assertEqual(payload["text"], message.replace("\\n", "\n"))
                self.assertEqual(payload["reply_markup"], expected_markup)
        finally:
            capture.unlink(missing_ok=True)
            (Path(directory) / ".last_ui_id").unlink(missing_ok=True)
            Path(directory).rmdir()

    def test_rename_rejects_sql_injection_before_db(self):
        arm = source_arm(self.master, "                do_rename:*)", "\n                ota_confirm:*)")
        arm = arm.replace("continue", "break")
        target = "node'; DROP TABLE nodes;--"
        result = run_bash(
            """
set +e
CHAT_ID=123
TEXT=%s
DB_CALLS=0
db_exec() { DB_CALLS=$((DB_CALLS + 1)); printf 'DB_CALLED\\n'; }
send_msg() { printf 'SENT:%%s\\n' "$2"; }
while :; do
    case "$TEXT" in
%s
    esac
    break
done
printf 'DB_CALLS=%%s\\n' "$DB_CALLS"
""" % (shlex.quote("do_rename:%s:safe" % target), arm)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DB_CALLS=0", result.stdout)
        self.assertNotIn("DB_CALLED", result.stdout)

    def test_single_actions_require_anchored_acceptance(self):
        ota_arm = source_arm(self.master, "                ota_execute:*)", "\n                report:*|log:*|quality:*)")
        report_arm = source_arm(self.master, "                report:*|log:*|quality:*)", "\n\n                trend:*)")
        quality_cli_arm = source_arm(self.master, "                \"/quality\"|\"/quality@\"*)", "\n\n                \"vhist:")
        failures = (
            "FAILED_NO_PSK",
            "FAILED_TLS_MISMATCH",
            "401 Unauthorized",
            "403 Forbidden",
            "unexpected failure",
            "rejected: expected Action Accepted: trigger_quality",
            "Action Accepted",
        )
        for response in failures:
            for arm, text in ((ota_arm, "ota_execute:node-1"),
                              (report_arm, "quality:node-1"),
                              (quality_cli_arm, "/quality@bot node-1")):
                with self.subTest(response=response, command=text):
                    result = run_case(arm, text, response)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn("SENT:✅", result.stdout)

        for arm, text in ((ota_arm, "ota_execute:node-1"),
                          (report_arm, "report:node-1"),
                          (report_arm, "log:node-1"),
                          (report_arm, "quality:node-1"),
                          (quality_cli_arm, "/quality@bot node-1")):
            with self.subTest(command=text):
                result = run_case(arm, text, "Action Accepted: trigger_quality")
                self.assertIn("SENT:✅", result.stdout)

    def test_fleet_ota_summary_collects_mixed_dispatch_results(self):
        arm = source_arm(self.master, "                \"all_ota_execute\")", "\n                \"master_ota_confirm\")")
        result = run_bash(
            """
set +e
CHAT_ID=123
CB_ID=callback
MSG_ID=
TEXT=all_ota_execute
db_exec() {
    printf 'node-a|Alpha|198.51.100.1|443\\n'
    printf 'node-b|Beta|198.51.100.2|443\\n'
    printf 'node-c|Gamma|198.51.100.3|443\\n'
    printf 'node-d|Delta|198.51.100.4|443\\n'
}
call_agent() {
    case "$1" in
        node-a|node-c) return 0 ;;
        node-b) return 2 ;;
        node-d) return 5 ;;
    esac
    return 1
}
render_msg() { :; }
send_msg() { printf 'SENT:%%s\\n' "$2"; }
sleep() { :; }
case "$TEXT" in
%s
esac
""" % arm
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("已接受: 2/4 台", result.stdout)
        self.assertIn("失败: 2 台", result.stdout)
        self.assertIn("Beta: FAILED_NO_PSK", result.stdout)
        self.assertIn("Delta: HTTP 403", result.stdout)
        self.assertIn("非升级完成", result.stdout)

    def test_region_verdicts_keep_raw_yt_observations(self):
        cases = (
            ("US", {"jump": "www.google.com", "prem": "US", "music": "US"}),
            ("HK", {"jump": "www.google.com.hk", "prem": "HK", "music": "HK"}),
            ("AU", {"jump": "www.google.com.au", "prem": "AU", "music": "AU"}),
            ("UK", {"jump": "google.co.uk", "prem": "GB", "music": "GB"}),
            ("GB", {"jump": "google.co.uk", "prem": "GB", "music": "GB"}),
        )
        for region, probe in cases:
            with self.subTest(region=region):
                output = mock.mock_open()
                with mock.patch.object(self.engine, "log"), mock.patch("builtins.open", output):
                    verdict = self.engine.region_verdict("test-node", region, probe)
                self.assertEqual(verdict, "OK")
                written = "".join(call.args[0] for call in output.return_value.write.call_args_list)
                self.assertIn('"prem": "%s"' % probe["prem"], written)
                self.assertIn('"music": "%s"' % probe["music"], written)
                expected_gl = "AU" if region == "AU" else "UK" if region in ("UK", "GB") else region
                self.assertEqual(self.engine._domain_to_gl(probe["jump"]), expected_gl)


if __name__ == "__main__":
    unittest.main()
