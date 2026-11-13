#!/usr/bin/env python3
"""Check ownership transfer with real launchd jobs and direct SSH commands."""

import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import uuid


def launchctl(*arguments, check=True):
    return subprocess.run(
        ["/bin/launchctl", *arguments], capture_output=True,
        text=True, check=check, timeout=10,
    )


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def check_retirement(folder):
    domain = f"gui/{os.getuid()}"
    labels = [f"app.pipedesk.test.{uuid.uuid4().hex}" for _ in range(2)]
    aliases = [f"pipedesk-test-{uuid.uuid4().hex}.invalid" for _ in range(2)]
    try:
        for label, alias in zip(labels, aliases):
            profile = {
                "Label": label,
                "ProgramArguments": [
                    "/usr/bin/ssh", "-N", "-o", "BatchMode=yes",
                    "-o", "ExitOnForwardFailure=yes", alias,
                ],
                "RunAtLoad": True,
                "KeepAlive": True,
                "ThrottleInterval": 60,
                "StandardErrorPath": "/dev/null",
            }
            path = folder / f"{label}.plist"
            path.write_bytes(plistlib.dumps(profile))
            launchctl("bootstrap", domain, str(path))
        loaded = launchctl("print", f"{domain}/{labels[0]}")
        match = re.search(r"\bpid = (\d+)", loaded.stdout)
        retired_pid = int(match.group(1)) if match else None
        launchctl("print", f"{domain}/{labels[1]}")
        subprocess.run(
            [str(Path(".build/tests/ssh").resolve()), "--retire-agent", str(folder), aliases[0]],
            check=True, timeout=20,
        )
        if launchctl("print", f"{domain}/{labels[0]}", check=False).returncode == 0:
            raise RuntimeError("The duplicate job remains loaded")
        disabled = launchctl("print-disabled", domain).stdout
        if f'"{labels[0]}" => disabled' not in disabled:
            raise RuntimeError("The duplicate job can return at login")
        deadline = time.monotonic() + 5
        while retired_pid and process_exists(retired_pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        if retired_pid and process_exists(retired_pid):
            raise RuntimeError("The duplicate SSH process survived retirement")
        launchctl("print", f"{domain}/{labels[1]}")
        print("PASS: duplicate SSH job stops and stays disabled; unrelated job remains", flush=True)
    finally:
        for label in labels:
            launchctl("bootout", f"{domain}/{label}", check=False)
            launchctl("enable", f"{domain}/{label}", check=False)


def main():
    with tempfile.TemporaryDirectory(prefix="pipedesk-agent-") as directory:
        check_retirement(Path(directory))


if __name__ == "__main__":
    main()
