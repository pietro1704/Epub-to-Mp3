"""Supervised archive commands with owned logs, receipts and process cleanup."""

import hosted_archive_contracts as contracts
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
from hosted_archive_contracts import (
    Blocked,
)


class ArchiveCommands:
    def __init__(self, reports, report, sequence=0):
        self.reports, self.report, self.sequence = reports, report, sequence

    @staticmethod
    def stop(process):
        if process.pid <= 1 or process.pid == os.getpgrp():
            raise Blocked("Invalid owned process group")
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        # A leader may exit while descendants ignore TERM.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


    def command(self, arguments, timeout=60, monitor=None, allow_failure=False, consumer=None):
        if consumer is not None and allow_failure:
            raise Blocked("Streaming validation requires successful process completion")
        self.sequence += 1
        log = self.reports / f"{self.sequence:02d}-{Path(arguments[0]).name}.log"
        deadline = time.monotonic() + timeout
        with log.open("xb") as output:
            process = subprocess.Popen(arguments, stdout=subprocess.PIPE if consumer else output,
                                       stderr=output if consumer else subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True,
                                       env={**os.environ, "LC_ALL": "C"})
            active = self.reports / "active-command.json"
            selector = None
            try:
                active.write_text(json.dumps({"pid": process.pid, "tool": Path(arguments[0]).name}))
                if consumer:
                    selector = selectors.DefaultSelector()
                    os.set_blocking(process.stdout.fileno(), False)
                    selector.register(process.stdout, selectors.EVENT_READ)
                while process.poll() is None or (selector is not None and selector.get_map()):
                    if time.monotonic() >= deadline or log.stat().st_size > contracts.MAX_LOG:
                        raise Blocked("Owned command exceeded its time/log budget")
                    if monitor:
                        monitor()
                    if selector is None:
                        time.sleep(0.1)
                    else:
                        for key, _ in selector.select(timeout=0.1):
                            try:
                                chunk = os.read(key.fd, contracts.STREAM_CHUNK)
                            except BlockingIOError:
                                continue
                            if chunk:
                                consumer.feed(chunk)
                            else:
                                selector.unregister(key.fileobj)
                if process.returncode != 0 and not allow_failure:
                    raise Blocked(f"{Path(arguments[0]).name} failed; see {log.name}")
                if log.stat().st_size > contracts.MAX_LOG:
                    raise Blocked("Command output exceeded the metadata budget")
                if consumer:
                    consumer.finish()
            finally:
                try:
                    self.stop(process)
                    active.unlink(missing_ok=True)
                finally:
                    try:
                        if selector is not None:
                            selector.close()
                    finally:
                        if process.stdout is not None:
                            process.stdout.close()
                    if selector is not None:
                        if sys.exc_info()[0] is not None:
                            consumer.complete = False
                        unwinding = sys.exc_info()[0] is not None
                        try:
                            self.report[getattr(consumer, "report_key", "payload_listing")] = consumer.receipt()
                        except Exception:
                            # Never replace the original process/validation error,
                            # but require a receipt before successful expansion.
                            if not unwinding:
                                raise
        if log.stat().st_size > contracts.MAX_LOG:
            raise Blocked("Command output exceeded the metadata budget")
        if consumer:
            return consumer.entries
        result = log.read_bytes()
        return (result, process.returncode) if allow_failure else result
