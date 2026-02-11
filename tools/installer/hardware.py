"""Bridge to tools/hardware_audit.py detection and benchmark functions."""

import sys
from pathlib import Path

# Add the tools/ directory to sys.path so we can import hardware_audit
_tools_dir = str(Path(__file__).resolve().parent.parent)
if _tools_dir not in sys.path:
    sys.path.insert(0, _tools_dir)

from hardware_audit import (  # noqa: E402
    read_cpuinfo,
    detect_arch_level,
    detect_virtualization,
    run_benchmark,
    recommend_profiles,
)

__all__ = [
    "read_cpuinfo",
    "detect_arch_level",
    "detect_virtualization",
    "run_benchmark",
    "recommend_profiles",
]
