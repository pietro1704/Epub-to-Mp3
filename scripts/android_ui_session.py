"""Bound one Android verification lifecycle; conversion acceptance is separate."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

PACKAGE = "com.pietrocode.epubtomp3.flutter_app.verification"


def write_json(path, value):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


class Device:
    def __init__(self, config):
        self.config = config
        self.prefix = [config["adb"], "-s", config["serial"]]
        self.budget(20)

    def budget(self, seconds):
        self.deadline = time.monotonic() + seconds

    def call(self, *arguments, timeout_seconds=3):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Device query budget exhausted")
        result = subprocess.run(
            [*self.prefix, *arguments], capture_output=True, text=True,
            timeout=min(timeout_seconds, remaining), check=True,
        )
        return result.stdout.strip()

    def shell(self, *arguments):
        return self.call("shell", *arguments)

    def identity(self):
        if self.call("get-state") != "device":
            raise ValueError("Device is not attached")
        if self.shell("run-as", PACKAGE, "id", "-u") != str(self.config["uid"]):
            raise ValueError("Package UID changed")
        apk = self.shell("pm", "path", PACKAGE)
        if not re.fullmatch(r"package:/data/app/[A-Za-z0-9_./+=-]+/base\.apk", apk):
            raise ValueError("Ambiguous APK path")
        for path, digest in [
            (apk[8:], self.config["apkSha256"]),
            ("app_flutter/flutter_assets/kernel_blob.bin", self.config["kernelSha256"]),
        ]:
            arguments = ("sha256sum", path)
            if not path.startswith("/data/app/"):
                arguments = ("run-as", PACKAGE, *arguments)
            fields = self.shell(*arguments).split()
            if len(fields) != 2 or fields[0] != digest or fields[1] != path:
                raise ValueError("APK or kernel identity changed")

    def processes(self):
        lines = self.shell("ps", "-A", "-o", "PID,UID,NAME").splitlines()
        if not lines or lines[0].split() != ["PID", "UID", "NAME"]:
            raise ValueError("Invalid process inventory header")
        if len(lines) > 4097:
            raise ValueError("Process inventory exceeds its bound")
        found = []
        seen = set()
        for line in lines[1:]:
            fields = line.split()
            if len(fields) != 3 or not all(value.isdecimal() for value in fields[:2]):
                raise ValueError("Invalid process inventory row")
            pid, uid = map(int, fields[:2])
            if pid in seen:
                raise ValueError("Duplicate process identity")
            seen.add(pid)
            name = fields[2]
            if name != PACKAGE and not name.startswith(PACKAGE + ":"):
                if uid == self.config["uid"]:
                    raise ValueError("Unexpected process identity for the package UID")
                continue
            if uid != self.config["uid"]:
                raise ValueError("Foreign package process UID")
            if len(found) >= 8:
                raise ValueError("Package process inventory exceeds its bound")
            stat = self.shell("run-as", PACKAGE, "cat", f"/proc/{pid}/stat")
            close = stat.rfind(")")
            values = stat[close + 2:].split()
            if close < 0 or stat.split(" ", 1)[0] != str(pid) or len(values) < 20:
                raise ValueError("Invalid package process identity")
            found.append({"pid": pid, "uid": uid, "starttime": int(values[19]), "name": name})
        return sorted(found, key=lambda value: value["pid"])


def validate_config(config):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", config["serial"]):
        raise ValueError("Invalid serial")
    if type(config["uid"]) is not int or config["uid"] < 10000:
        raise ValueError("Invalid app UID")
    for key in ["apkSha256", "kernelSha256"]:
        if not re.fullmatch(r"[0-9a-f]{64}", config[key]):
            raise ValueError("Invalid identity digest")
    for key in ["runner", "wrapper"]:
        item = config[key]
        path = Path(item["path"])
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise ValueError("Noncanonical dependency")
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Dependency fingerprint changed")
    for key in ["adb", "python", "ruby", "cwd"]:
        path = Path(config[key])
        if not path.is_absolute() or not path.exists():
            raise ValueError("Missing absolute dependency")
    if not 1 <= config["seconds"] <= 1800:
        raise ValueError("Invalid session deadline")


def guarded_command(config, directory):
    return [
        config["python"], config["runner"]["path"], "--cwd", config["cwd"],
        "--log", str(directory / "resource-run"), "--seconds", str(config["seconds"]),
        "--profile", "gradle-1024", "--", config["ruby"],
        config["wrapper"]["path"], "--", config["python"], str(Path(__file__).resolve()),
        "--wait", str(directory),
    ]


def host_identity(pid):
    path = Path(f"/proc/{pid}")
    stat = (path / "stat").read_text()
    values = stat[stat.rfind(")") + 2:].split()
    if values[0] in ("Z", "X", "x"):
        raise ValueError("Guard process is not live")
    return {"pid": pid, "ppid": int(values[1]), "starttime": int(values[19]),
            "pgid": int(values[2]), "uid": path.stat().st_uid}


def remaining_groups(identities):
    groups = {value["pgid"] for value in identities}
    deadline = time.monotonic() + 1
    remaining = []
    for count, entry in enumerate(Path("/proc").iterdir()):
        if count >= 4096 or time.monotonic() >= deadline:
            raise TimeoutError("Host cleanup inventory exceeds its bound")
        if not entry.name.isdecimal():
            continue
        try:
            stat = (entry / "stat").read_text()
            values = stat[stat.rfind(")") + 2:].split()
            if int(values[2]) in groups:
                remaining.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError):
            continue
    return remaining


def admitted_child(directory, runner, created_ns):
    path = directory / "guard-ready.json"
    if path.stat().st_mtime_ns < created_ns:
        raise ValueError("Stale guard handshake")
    receipt = read_json(path)
    if receipt["pid"] == runner.pid:
        raise ValueError("Handshake must come from the guarded child")
    identity = host_identity(receipt["pid"])
    if receipt != {"ready": True, **identity} or identity["uid"] != os.getuid():
        raise ValueError("Guard child identity changed")
    ancestor = identity
    chain = []
    for _ in range(12):
        if ancestor["uid"] != os.getuid() or ancestor["pgid"] == os.getpgrp():
            raise ValueError("Guard ancestry ownership changed")
        chain.append(ancestor)
        if ancestor["pid"] == runner.pid:
            if runner.poll() is not None or host_identity(identity["pid"]) != identity:
                raise ValueError("Guard or child exited before launch")
            return chain
        if ancestor["ppid"] <= 1:
            break
        ancestor = host_identity(ancestor["ppid"])
    raise ValueError("Handshake is not from the guarded child")


def wait_for_operator(directory):
    # This child only holds the existing guard/lease. It does not operate the UI.
    write_json(directory / "guard-ready.json", {"ready": True, **host_identity(os.getpid())})
    while not (directory / "finish.json").exists():
        time.sleep(0.1)
    return 0


def run_session(config, root, session_id):
    validate_config(config)
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", session_id):
        raise ValueError("Invalid session ID")
    if root.is_symlink() or root.resolve() != root.absolute():
        raise ValueError("Noncanonical state root")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise ValueError("State root must be private and owned")
    for previous in root.iterdir():
        if not previous.is_dir() or previous.is_symlink():
            raise ValueError("Unknown session state")
        if read_json(previous / "lifecycle.json").get("cleanupVerified") is not True:
            raise ValueError("Previous cleanup is unproven")
    device = Device(config)
    device.identity()
    if device.processes():
        raise ValueError("Verification package is already active")
    directory = root / session_id
    directory.mkdir(mode=0o700, exist_ok=False)
    created_ns = time.time_ns()
    report = {
        "package": PACKAGE, "serial": config["serial"], "status": 125,
        "cleanupVerified": False, "conversionAccepted": False,
        "continuousKernelLease": False, "operationalSoleExecutorRequired": True,
        "started": False, "processes": [],
    }
    write_json(directory / "lifecycle.json", report)
    stop = [0]
    previous_handlers = {}
    process = None
    log = None
    identities = []
    full_chain_authenticated = False
    interruption = 0
    try:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[number] = signal.signal(number, lambda sig, frame: stop.__setitem__(0, sig))
        command = guarded_command(config, directory)
        write_json(directory / "command.json", command)
        log = (directory / "host.log").open("x")
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        identities.append(host_identity(process.pid))
        started = time.monotonic()
        deadline = started + config["seconds"]
        while process.poll() is None:
            if stop[0] or time.monotonic() >= deadline:
                interruption = 128 + stop[0] if stop[0] else 124
                report["status"] = interruption
                break
            if (directory / "guard-ready.json").exists() and not report["started"]:
                identities = admitted_child(directory, process, created_ns)
                full_chain_authenticated = True
                report["hostIdentities"] = identities
                device.budget(min(10, deadline - time.monotonic()))
                device.identity()
                if device.processes():
                    raise ValueError("Package became active before owned launch")
                admitted_child(directory, process, created_ns)
                if stop[0] or time.monotonic() >= deadline:
                    interruption = 128 + stop[0] if stop[0] else 124
                    report["status"] = interruption
                    break
                report["launchAttempted"] = True
                write_json(directory / "lifecycle.json", report)
                device.call(
                    "shell", "am", "start", "-n",
                    PACKAGE + "/com.pietrocode.epubtomp3.flutter_app.MainActivity",
                    timeout_seconds=10,
                )
                owned = device.processes()
                if not owned:
                    raise ValueError("Owned launch has no authenticated process")
                report.update(started=True, processes=owned)
                write_json(directory / "lifecycle.json", report)
            time.sleep(0.1)
        if process.poll() is not None and not interruption:
            code = process.returncode
            report["status"] = code if code >= 0 else 128 - code
            if not report["started"] and report["status"] == 0:
                report["status"] = 75
        if stop[0]:
            report["status"] = 128 + stop[0]
    except Exception as error:
        report.update(status=125, error=type(error).__name__)
        if isinstance(error, (subprocess.TimeoutExpired, subprocess.CalledProcessError)):
            report["errorCommand"] = error.cmd
        if isinstance(error, subprocess.TimeoutExpired):
            report["errorTimeoutSeconds"] = error.timeout
    finally:
        host_reaped = process is None
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=20)
                host_reaped = True
            except subprocess.TimeoutExpired:
                # Do not claim cleanup or signal an unverified descendant group.
                report.update(status=125, hostCleanupError="Runner did not terminate")
        report["hostRunnerReaped"] = host_reaped
        try:
            device.budget(12)
            device.identity()
            current = device.processes()
            if current:
                if not report["started"] or current != report["processes"]:
                    raise ValueError("Package process identity changed before cleanup")
                device.shell("am", "force-stop", PACKAGE)
            if device.processes():
                raise ValueError("Package processes remain after cleanup")
            report["deviceCleanupVerified"] = True
        except Exception as error:
            report.update(status=125, cleanupError=type(error).__name__)
        try:
            report["remainingHostGroupPids"] = remaining_groups(identities)
            report["hostGroupsAbsent"] = not report["remainingHostGroupPids"]
        except Exception as error:
            report.update(status=125, hostCleanupError=type(error).__name__)
        report["hostGroupsAuthenticated"] = full_chain_authenticated
        report["cleanupVerified"] = bool(host_reaped and report["hostGroupsAuthenticated"]
                                         and report.get("hostGroupsAbsent")
                                         and report.get("deviceCleanupVerified"))
        if not report["cleanupVerified"]:
            report["status"] = 125
        if log is not None:
            log.close()
        if stop[0] and report["cleanupVerified"]:
            report["status"] = 128 + stop[0]
        report["interrupted"] = report["status"] != 0
        report["deviceProcessTerminationIsGracefulCancellation"] = False
        write_json(directory / "lifecycle.json", report)
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
    print(json.dumps(report), flush=True)
    return report["status"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--state-root", type=Path)
    parser.add_argument("--session-id")
    parser.add_argument("--sole-executor", action="store_true")
    parser.add_argument("--wait", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This coordinator requires Linux")
    if args.wait is not None:
        return wait_for_operator(args.wait)
    if not all([args.config, args.state_root, args.session_id, args.sole_executor]):
        parser.error("Explicit config, state root, session ID and sole executor are required")
    try:
        return run_session(read_json(args.config), args.state_root, args.session_id)
    except Exception as error:
        print(json.dumps({"status": 75, "started": False, "error": type(error).__name__}), flush=True)
        return 75


if __name__ == "__main__":
    raise SystemExit(main())
