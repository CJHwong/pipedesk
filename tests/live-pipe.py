#!/usr/bin/env python3
"""Check real Dumbpipe forwarding with synthetic bytes and a retained identity."""

import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time


PAYLOAD = b"PipeDesk synthetic transport check\n"
TICKET = re.compile(r"\b(?:endpoint|node)[a-zA-Z0-9]{30,}\b")


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            received = self.request.recv(4096)
            self.request.sendall(received)
        except (OSError, TimeoutError):
            return


class EchoServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def start_process(binary, arguments, identity, folder, label, processes):
    environment = os.environ.copy()
    environment["IROH_SECRET"] = identity
    log_path = folder / (label + ".log")
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        process = subprocess.Popen(
            [binary, *arguments], env=environment, stdin=subprocess.DEVNULL,
            stdout=output, stderr=subprocess.STDOUT,
        )
    processes.append(process)
    return process, log_path


def stop_process(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def wait_ticket(process, log_path, deadline):
    while time.monotonic() < deadline:
        match = TICKET.search(log_path.read_text(errors="replace"))
        if match:
            return match.group()
        if process.poll() is not None:
            raise RuntimeError("Listener exited before it produced a ticket")
        time.sleep(0.1)
    raise RuntimeError("Listener did not produce a ticket before the deadline")


def check_echo(port, connector, listener, deadline):
    while time.monotonic() < deadline:
        if connector.poll() is not None or listener.poll() is not None:
            raise RuntimeError("A Dumbpipe process exited before the echo check")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
                connection.sendall(PAYLOAD)
                response = connection.recv(4096)
            if response == PAYLOAD:
                return
        except (OSError, TimeoutError):
            time.sleep(0.2)
    raise RuntimeError("Synthetic echo did not return before the deadline")


def stable_ticket(binary, identity):
    environment = os.environ.copy()
    environment["IROH_SECRET"] = identity
    result = subprocess.run(
        [binary, "generate-ticket"], env=environment, capture_output=True,
        text=True, timeout=10, check=False,
    )
    match = TICKET.search(result.stdout + result.stderr)
    if result.returncode != 0 or match is None:
        raise RuntimeError("Dumbpipe could not generate a stable ticket")
    return match.group()


def check_transport(binary, folder, server, processes):
    deadline = time.monotonic() + 95
    identity = secrets.token_hex(32)
    identity_path = folder / "listener.key"
    descriptor = os.open(identity_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as identity_file:
        identity_file.write(identity)
    ticket = stable_ticket(binary, identity)
    service_port = server.server_address[1]
    listener_arguments = ["listen-tcp", "--host", f"127.0.0.1:{service_port}"]
    listener, listener_log = start_process(binary, listener_arguments, identity, folder, "listener", processes)
    advertised_ticket = wait_ticket(listener, listener_log, deadline)
    local_port = available_port()
    connector_arguments = ["connect-tcp", "--addr", f"127.0.0.1:{local_port}", advertised_ticket]
    connector, _ = start_process(binary, connector_arguments, secrets.token_hex(32), folder, "connector", processes)
    check_echo(local_port, connector, listener, deadline)
    print("PASS: listener ticket forwards synthetic bytes", flush=True)
    stop_process(connector)
    stop_process(listener)
    retained_identity = identity_path.read_text()
    if stable_ticket(binary, retained_identity) != ticket:
        raise RuntimeError("Retained identity produced a different stable ticket")
    listener, listener_log = start_process(binary, listener_arguments, retained_identity, folder, "restarted-listener", processes)
    wait_ticket(listener, listener_log, deadline)
    connector_arguments[-1] = ticket
    connector, _ = start_process(binary, connector_arguments, secrets.token_hex(32), folder, "restarted-connector", processes)
    check_echo(local_port, connector, listener, deadline)
    print("PASS: retained identity reconnects with the original stable ticket", flush=True)


def check_runtime(folder, server):
    executable = os.environ.get("PIPEDESK_RUNTIME_TEST_BIN")
    if not executable:
        return
    environment = os.environ.copy()
    config_folder = folder / "runtime-config"
    config_folder.mkdir(mode=0o700)
    environment["PIPEDESK_CONFIG_DIR"] = str(config_folder)
    result = subprocess.run(
        [executable, str(server.server_address[1])], env=environment,
        stdin=subprocess.DEVNULL, timeout=120, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"PipeDesk runtime check exited with code {result.returncode}")
    print("PASS: PipeDesk runtime forwards synthetic bytes", flush=True)


def run_server(binary, folder, server):
    processes = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        check_transport(binary, folder, server, processes)
        check_runtime(folder, server)
    finally:
        for process in reversed(processes):
            stop_process(process)
        server.shutdown()
        thread.join(timeout=3)


def main():
    binary = os.environ.get("DUMBPIPE_BIN") or shutil.which("dumbpipe")
    if not binary:
        raise RuntimeError("Dumbpipe is missing; install it or set DUMBPIPE_BIN")
    with tempfile.TemporaryDirectory(prefix="pipedesk-live-") as directory:
        with EchoServer(("127.0.0.1", 0), EchoHandler) as server:
            run_server(binary, Path(directory), server)
    print("PASS: owned processes and temporary files removed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"FAIL: {error}") from None
