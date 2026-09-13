"""Offline scheduler regressions: real Bash blocks, mocked processes and I/O."""

from pathlib import Path
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "master/engine/scheduler.sh").read_text(encoding="utf-8")
BASH = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt"
        else shutil.which("bash"))


def function(name):
    start = SOURCE.index(name + "() {")
    return SOURCE[start:SOURCE.index("\n}", start) + 2]


def shell(script):
    result = subprocess.run([BASH], input=script, text=True, encoding="utf-8",
                            capture_output=True, timeout=10)
    if result.returncode or result.stderr:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout.splitlines()


@unittest.skipUnless(BASH and Path(BASH).exists(), "Bash unavailable")
class SchedulerTests(unittest.TestCase):
    def scan(self, nodes, triggers=(), failed=(), busy=(), active=0):
        # Execute the production SELECT, including its paused-node behavior.
        query = re.search(r'NODES=\$\(db_exec "(SELECT[^"\n]+)"\)', SOURCE)[1]
        db = sqlite3.connect(":memory:")
        try:
            db.execute("CREATE TABLE nodes(node_name,region,lang_params,base_lat,"
                       "base_lon,agent_ip,engine_enabled,psk,last_seen)")
            for index, (name, enabled) in enumerate(nodes):
                db.execute("INSERT INTO nodes VALUES(?,?,?,?,?,?,?,?,?)",
                           (name, "US", "", "", "", "203.0.113.1", enabled,
                            "test", 100 - index))
            rows = "\n".join("|".join(map(str, row)) for row in db.execute(query))
        finally:
            db.close()
        setup = f"""
ENGINE_CONCURRENCY=2
ENGINE_MIN_INTERVAL=5400
STATE_DIR=/mock-scheduler
ROWS={shlex.quote(rows)}
FAILED={shlex.quote(' ' + ' '.join(failed) + ' ')}
BUSY={shlex.quote(' ' + ' '.join(busy) + ' ')}
declare -A TRIG=()
active_sessions() {{ echo {active}; }}
db_exec() {{ printf '%s\\n' "$ROWS"; }}
date() {{ echo 20000; }}
log() {{ :; }}
stat() {{ echo mock; }}
function [() {{
    if [[ "$1" == -f ]]; then [[ -n "${{TRIG[$2]:-}}" ]];
    else builtin [ "$@"; fi
}}
cat() {{ printf '%s\\n' "${{TRIG[$1]:-}}"; }}
rm() {{ unset 'TRIG[$2]'; printf 'REMOVED %s\\n' "$2"; }}
node_running() {{ [[ "$BUSY" == *" $1 "* ]]; }}
launch_session() {{
    [[ "$FAILED" == *" $1 "* ]] && return 1
    printf 'LAUNCH %s %s\\n' "$1" "$7"
}}
"""
        for name, focus in triggers:
            setup += f"TRIG[/mock-scheduler/{name}.trigger]={shlex.quote(focus)}\n"
        body = SOURCE[SOURCE.index("    NOW=$(date +%s)"):
                      SOURCE.index("    # 扫描间隔随机抖动")]
        return shell(setup + function("consume_trigger") + "\n" + body +
                     '\nfor path in "${!TRIG[@]}"; do echo "PENDING $path"; done\n')

    def test_failed_launches_do_not_consume_slots(self):
        output = self.scan([(n, "true") for n in ("A", "B", "C", "D", "E")],
                           failed=("A", "B"))
        self.assertEqual(output, ["LAUNCH C all", "LAUNCH D all"])

    def test_paused_node_runs_manual_only(self):
        output = self.scan([("A", "false"), ("B", "false"), ("C", "true")],
                           triggers=(("A", "google"),))
        self.assertEqual(output, ["LAUNCH A google",
                                 "REMOVED /mock-scheduler/A.trigger", "LAUNCH C all"])
        self.assertEqual(self.scan([("A", "false")]), [])

    def test_manual_failure_or_busy_keeps_request_and_slot(self):
        for options in ({"failed": ("A",)}, {"busy": ("A",)}):
            with self.subTest(options=options):
                output = self.scan([("A", "false"), ("B", "true"), ("C", "true")],
                                   triggers=(("A", "trust"),), **options)
                self.assertEqual(output, ["LAUNCH B all", "LAUNCH C all",
                                         "PENDING /mock-scheduler/A.trigger"])

    def test_full_capacity_preserves_manual_request(self):
        self.assertEqual(self.scan([("A", "false")], triggers=(("A", "trust"),), active=2),
                         ["PENDING /mock-scheduler/A.trigger"])

    def test_count_excludes_timeout_and_unrelated_python(self):
        lines = ("timeout 1800 /opt/venv/bin/python3 /opt/engine/camoufox_session.py --node A\n"
                 "/opt/venv/bin/python3 /opt/engine/camoufox_session.py --node A\n"
                 "/opt/venv/bin/python3 /opt/engine/camoufox_session.py --node B\n"
                 "/opt/venv/bin/python3 other.py camoufox_session.py\n")
        for commands, expected in ((lines, "2"), ("", "0")):
            with self.subTest(expected=expected):
                # Real POSIX ERE matching; no Linux process inventory required.
                output = shell("COMMANDS=" + shlex.quote(commands) + "\n" +
                               'pgrep() { printf "%s" "$COMMANDS" | grep -Ec -- "$2"; }\n' +
                               function("active_sessions") + "\nactive_sessions\n")
                self.assertEqual(output, [expected])


if __name__ == "__main__":
    unittest.main()
