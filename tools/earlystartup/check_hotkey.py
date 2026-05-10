#!/usr/bin/env python3
"""Detect if F5 is held during boot (triggers AmiCachy Early Startup Control).

Uses Linux evdev ioctls via ctypes — no external dependencies.
The user must have read access to /dev/input/event* (group 'input').

Exit codes:
    0 — F5 detected as held
    1 — F5 not held (or no keyboard found)
"""

import fcntl
import os
import struct
import sys
import time
from pathlib import Path

# Linux input event constants (from <linux/input-event-codes.h>)
EV_KEY = 0x01
KEY_F5 = 63

# struct input_event { struct timeval time; __u16 type; __u16 code; __s32 value; }
# timeval is 16 B on 64-bit (long long sec, long long usec).
_EVENT_FMT = "llHHi"
_EVENT_SIZE = struct.calcsize(_EVENT_FMT)

# ioctl numbers (from <linux/input.h>)
_IOC_READ = 2


def _ioc(direction: int, typ: int, nr: int, size: int) -> int:
    return (direction << 30) | (typ << 8) | nr | (size << 16)


def _eviocgbit(ev: int, length: int) -> int:
    return _ioc(_IOC_READ, ord("E"), 0x20 + ev, length)


def _eviocgkey(length: int) -> int:
    return _ioc(_IOC_READ, ord("E"), 0x18, length)


def _test_bit(array: bytes, bit: int) -> bool:
    byte_idx = bit // 8
    bit_idx = bit % 8
    if byte_idx >= len(array):
        return False
    return bool(array[byte_idx] & (1 << bit_idx))


def _find_keyboards() -> list[Path]:
    """Find /dev/input/event* devices that have KEY_F5 capability."""
    keyboards = []
    input_dir = Path("/dev/input")
    if not input_dir.exists():
        return keyboards

    for dev in sorted(input_dir.glob("event*")):
        try:
            fd = os.open(str(dev), os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            # Query EV_KEY capability bitmap — 96 bytes = 768 bits,
            # more than enough for KEY_F5 (63)
            buf = bytearray(96)
            fcntl.ioctl(fd, _eviocgbit(EV_KEY, len(buf)), buf)
            if _test_bit(buf, KEY_F5):
                keyboards.append(dev)
        except OSError:
            pass
        finally:
            os.close(fd)

    return keyboards


def _check_key(dev: Path) -> bool:
    """Return True if F5 is currently pressed on the given device."""
    try:
        fd = os.open(str(dev), os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        buf = bytearray(96)
        fcntl.ioctl(fd, _eviocgkey(len(buf)), buf)
        return _test_bit(buf, KEY_F5)
    except OSError:
        return False
    finally:
        os.close(fd)


def _drain_events(fd: int) -> bool:
    """Read pending input_event records from fd. Return True if any of them
    was a F5 key-down. Non-blocking — returns immediately when there is
    nothing to read."""
    while True:
        try:
            data = os.read(fd, _EVENT_SIZE * 64)
        except BlockingIOError:
            return False
        except OSError:
            return False
        if not data:
            return False
        for i in range(0, len(data), _EVENT_SIZE):
            chunk = data[i : i + _EVENT_SIZE]
            if len(chunk) != _EVENT_SIZE:
                break
            _sec, _usec, ev_type, ev_code, ev_value = struct.unpack(_EVENT_FMT, chunk)
            if ev_type == EV_KEY and ev_code == KEY_F5 and ev_value == 1:
                return True


def main() -> int:
    """Detect F5 within a tunable window via two paths:
       (a) EVIOCGKEY snapshot — catches the user holding F5 down.
       (b) reading input_event stream — catches a fugacious keypress whose
           edge would otherwise be missed by the snapshot.
    Re-enumerate keyboards each iteration so we still catch a USB / Spice
    keyboard that surfaces a few hundred ms into the window.

    Window length defaults to 8s but can be overridden with $AMICACHY_HOTKEY_WINDOW."""
    try:
        window = float(os.environ.get("AMICACHY_HOTKEY_WINDOW", "8"))
    except ValueError:
        window = 8.0
    open_fds: dict[Path, int] = {}
    deadline = time.monotonic() + window
    try:
        while time.monotonic() < deadline:
            for dev in _find_keyboards():
                if dev not in open_fds:
                    try:
                        open_fds[dev] = os.open(
                            str(dev), os.O_RDONLY | os.O_NONBLOCK
                        )
                    except OSError:
                        continue
                fd = open_fds[dev]
                # (a) Held-key snapshot
                buf = bytearray(96)
                try:
                    fcntl.ioctl(fd, _eviocgkey(len(buf)), buf)
                    if _test_bit(buf, KEY_F5):
                        return 0
                except OSError:
                    pass
                # (b) Event stream
                if _drain_events(fd):
                    return 0
            time.sleep(0.05)
        return 1
    finally:
        for fd in open_fds.values():
            try:
                os.close(fd)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
