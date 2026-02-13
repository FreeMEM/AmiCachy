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
import sys
import time
from pathlib import Path

# Linux input event constants (from <linux/input-event-codes.h>)
EV_KEY = 0x01
KEY_F5 = 63

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


def main() -> int:
    keyboards = _find_keyboards()
    if not keyboards:
        return 1

    # Sample 5 times over 500ms — F5 must be held on at least one sample.
    for _ in range(5):
        for dev in keyboards:
            if _check_key(dev):
                return 0
        time.sleep(0.1)

    return 1


if __name__ == "__main__":
    sys.exit(main())
