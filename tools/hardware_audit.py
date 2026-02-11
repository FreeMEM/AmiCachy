#!/usr/bin/env python3
"""AmiCachy Hardware Audit — PySide6 GUI
Detects CPU capabilities, virtualization support, runs a single-core
benchmark, and recommends which AmiCachy profiles are viable.
Results can be exported to JSON for the installer.
"""

import json
import math
import os
import struct
import sys
import time
from pathlib import Path

from PySide6.QtCore import QThread, Signal, Qt
from PySide6.QtGui import QColor, QFont
from PySide6.QtWidgets import (
    QApplication,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

# ---------------------------------------------------------------------------
# Hardware detection helpers
# ---------------------------------------------------------------------------

def read_cpuinfo() -> dict:
    """Parse /proc/cpuinfo and return a dict with relevant fields."""
    info: dict = {"model": "Unknown", "flags": [], "cores": 0, "threads": 0}
    try:
        text = Path("/proc/cpuinfo").read_text()
        processors = text.strip().split("\n\n")
        info["threads"] = len(processors)

        core_ids: set[str] = set()
        for block in processors:
            for line in block.splitlines():
                key, _, value = line.partition(":")
                key = key.strip()
                value = value.strip()
                if key == "model name":
                    info["model"] = value
                elif key == "flags":
                    info["flags"] = value.split()
                elif key == "core id":
                    core_ids.add(value)
        info["cores"] = len(core_ids) if core_ids else info["threads"]
    except OSError:
        pass
    return info


def detect_arch_level(flags: list[str]) -> str:
    """Determine x86-64 architecture level from CPU flags."""
    has = set(flags)
    if {"avx512f", "avx512bw", "avx512cd", "avx512dq", "avx512vl"} <= has:
        return "x86-64-v4"
    if {"avx2", "bmi1", "bmi2", "fma", "lzcnt", "movbe"} <= has:
        return "x86-64-v3"
    if {"cx16", "lahf_lm", "popcnt", "sse4_1", "sse4_2", "ssse3"} <= has:
        return "x86-64-v2"
    return "x86-64 (baseline)"


def detect_virtualization(flags: list[str]) -> dict:
    """Check for VT-x (vmx) or AMD-V (svm) support."""
    has = set(flags)
    return {
        "intel_vtx": "vmx" in has,
        "amd_svm": "svm" in has,
        "supported": ("vmx" in has) or ("svm" in has),
    }


# ---------------------------------------------------------------------------
# Single-core benchmark
# ---------------------------------------------------------------------------

# Reference score: approximate single-core throughput of an AmigaOne X5000
# (Cyrus+ P5020 dual-core PPC @ 2.0 GHz).  This is a *relative* value tuned
# so that a modern desktop CPU scores well above 1.0x.
X5000_REFERENCE = 38_000_000


def run_benchmark(duration_s: float = 3.0) -> dict:
    """CPU-bound loop that measures iterations/sec (single-core)."""
    iterations = 0
    start = time.perf_counter()
    deadline = start + duration_s
    x = 1.0
    while time.perf_counter() < deadline:
        for _ in range(10_000):
            x = math.sin(x + 1.0) * math.cos(x - 1.0) + math.sqrt(abs(x) + 1.0)
            iterations += 1
    elapsed = time.perf_counter() - start
    rate = iterations / elapsed
    ratio = rate / X5000_REFERENCE
    return {
        "iterations": iterations,
        "elapsed_s": round(elapsed, 3),
        "rate": round(rate, 0),
        "x5000_ratio": round(ratio, 2),
    }


# ---------------------------------------------------------------------------
# Profile recommendation
# ---------------------------------------------------------------------------

def recommend_profiles(arch_level: str, virt: dict, bench: dict) -> list[dict]:
    """Return a list of profile dicts with status: green/yellow/red."""
    profiles = []

    # Classic 68k — always viable
    status = "green"
    note = "Fully supported on any modern CPU."
    profiles.append({"name": "Classic 68k", "status": status, "note": note})

    # PPC Nitro — needs virt + decent CPU
    if not virt["supported"]:
        status = "red"
        note = "Virtualization (VT-x / AMD-V) not detected — PPC emulation unavailable."
    elif bench["x5000_ratio"] < 0.8:
        status = "red"
        note = f"CPU too slow for PPC emulation ({bench['x5000_ratio']}x X5000)."
    elif bench["x5000_ratio"] < 1.2:
        status = "yellow"
        note = f"Marginal for PPC ({bench['x5000_ratio']}x X5000). May stutter."
    else:
        status = "green"
        note = f"Excellent for PPC ({bench['x5000_ratio']}x X5000)."
    profiles.append({"name": "PPC Nitro", "status": status, "note": note})

    # Dev Station — needs v3+ for CachyOS optimized packages
    if arch_level in ("x86-64-v3", "x86-64-v4"):
        status = "green"
        note = f"CPU level {arch_level} — full CachyOS optimization."
    else:
        status = "yellow"
        note = f"CPU level {arch_level} — some CachyOS packages may fall back to generic."
    profiles.append({"name": "Dev Station", "status": status, "note": note})

    return profiles


# ---------------------------------------------------------------------------
# Benchmark worker thread
# ---------------------------------------------------------------------------

class BenchmarkWorker(QThread):
    finished = Signal(dict)

    def run(self):
        result = run_benchmark(duration_s=3.0)
        self.finished.emit(result)


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

STATUS_COLORS = {
    "green": "#27ae60",
    "yellow": "#f39c12",
    "red": "#c0392b",
}


def _section_label(text: str) -> QLabel:
    lbl = QLabel(text)
    font = QFont()
    font.setPointSize(13)
    font.setBold(True)
    lbl.setFont(font)
    lbl.setContentsMargins(0, 12, 0, 4)
    return lbl


def _info_label(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setWordWrap(True)
    lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
    return lbl


class AuditWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AmiCachy — Hardware Audit")
        self.setMinimumSize(640, 520)

        self._results: dict = {}
        self._bench_worker: BenchmarkWorker | None = None
        self._bench_result_data: dict = {}
        self._profiles_data: list[dict] = []

        # --- Gather hardware info ---
        self._cpuinfo = read_cpuinfo()
        self._arch_level = detect_arch_level(self._cpuinfo["flags"])
        self._virt = detect_virtualization(self._cpuinfo["flags"])

        # --- Build UI ---
        central = QWidget()
        self.setCentralWidget(central)
        root_layout = QVBoxLayout(central)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        root_layout.addWidget(scroll)

        container = QWidget()
        self._layout = QVBoxLayout(container)
        self._layout.setAlignment(Qt.AlignTop)
        scroll.setWidget(container)

        self._build_cpu_section()
        self._build_virt_section()
        self._build_bench_section()
        self._build_recommendation_section()
        self._build_actions()

    # -- CPU --
    def _build_cpu_section(self):
        self._layout.addWidget(_section_label("CPU"))
        self._layout.addWidget(_info_label(f"Model: {self._cpuinfo['model']}"))
        self._layout.addWidget(
            _info_label(f"Cores: {self._cpuinfo['cores']}  |  Threads: {self._cpuinfo['threads']}")
        )
        self._layout.addWidget(_info_label(f"Architecture level: {self._arch_level}"))

    # -- Virtualization --
    def _build_virt_section(self):
        self._layout.addWidget(_section_label("Virtualization"))
        if self._virt["intel_vtx"]:
            text = "Intel VT-x (vmx) detected."
        elif self._virt["amd_svm"]:
            text = "AMD-V (svm) detected."
        else:
            text = "No hardware virtualization detected — PPC emulation will not work."
        lbl = _info_label(text)
        if not self._virt["supported"]:
            lbl.setStyleSheet("color: #c0392b; font-weight: bold;")
        self._layout.addWidget(lbl)

    # -- Benchmark --
    def _build_bench_section(self):
        self._layout.addWidget(_section_label("Single-Core Benchmark"))
        self._bench_label = _info_label("Press 'Run Benchmark' to measure single-core performance.")
        self._layout.addWidget(self._bench_label)
        self._bench_progress = QProgressBar()
        self._bench_progress.setRange(0, 0)  # indeterminate
        self._bench_progress.setVisible(False)
        self._layout.addWidget(self._bench_progress)

        self._bench_btn = QPushButton("Run Benchmark")
        self._bench_btn.setFixedWidth(180)
        self._bench_btn.clicked.connect(self._start_benchmark)
        self._layout.addWidget(self._bench_btn)

    def _start_benchmark(self):
        self._bench_btn.setEnabled(False)
        self._bench_progress.setVisible(True)
        self._bench_label.setText("Running benchmark (≈3 seconds)…")
        self._bench_worker = BenchmarkWorker()
        self._bench_worker.finished.connect(self._on_benchmark_done)
        self._bench_worker.start()

    def _on_benchmark_done(self, result: dict):
        self._bench_progress.setVisible(False)
        self._bench_btn.setEnabled(True)
        self._bench_result = result
        self._bench_label.setText(
            f"Score: {int(result['rate']):,} iter/s  —  "
            f"{result['x5000_ratio']}x AmigaOne X5000 reference"
        )
        self._update_recommendations()

    # -- Recommendation --
    def _build_recommendation_section(self):
        self._layout.addWidget(_section_label("Profile Recommendations"))
        self._rec_container = QVBoxLayout()
        self._rec_placeholder = _info_label("Run the benchmark first to see recommendations.")
        self._rec_container.addWidget(self._rec_placeholder)
        self._layout.addLayout(self._rec_container)

    def _update_recommendations(self):
        # Clear old
        while self._rec_container.count():
            item = self._rec_container.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        profiles = recommend_profiles(self._arch_level, self._virt, self._bench_result)
        self._profiles = profiles

        for p in profiles:
            frame = QFrame()
            frame.setFrameShape(QFrame.StyledPanel)
            frame.setStyleSheet(
                f"QFrame {{ border-left: 4px solid {STATUS_COLORS[p['status']]}; padding: 6px; }}"
            )
            h = QHBoxLayout(frame)
            dot = QLabel("\u25cf")
            dot.setStyleSheet(f"color: {STATUS_COLORS[p['status']]}; font-size: 18px;")
            dot.setFixedWidth(24)
            h.addWidget(dot)
            h.addWidget(_info_label(f"<b>{p['name']}</b> — {p['note']}"))
            self._rec_container.addWidget(frame)

        self._export_btn.setEnabled(True)

    # -- Actions --
    def _build_actions(self):
        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        self._layout.addWidget(sep)

        btn_layout = QHBoxLayout()
        self._export_btn = QPushButton("Export JSON")
        self._export_btn.setFixedWidth(140)
        self._export_btn.setEnabled(False)
        self._export_btn.clicked.connect(self._export_json)
        btn_layout.addWidget(self._export_btn)
        btn_layout.addStretch()
        self._layout.addLayout(btn_layout)

    def _export_json(self):
        data = {
            "cpu": {
                "model": self._cpuinfo["model"],
                "cores": self._cpuinfo["cores"],
                "threads": self._cpuinfo["threads"],
                "arch_level": self._arch_level,
            },
            "virtualization": self._virt,
            "benchmark": self._bench_result,
            "profiles": self._profiles,
        }
        path, _ = QFileDialog.getSaveFileName(
            self, "Export audit results", "hardware_audit.json", "JSON files (*.json)"
        )
        if path:
            Path(path).write_text(json.dumps(data, indent=2))

    @property
    def _bench_result(self):
        return self._bench_result_data

    @_bench_result.setter
    def _bench_result(self, value):
        self._bench_result_data = value

    @property
    def _profiles(self):
        return self._profiles_data

    @_profiles.setter
    def _profiles(self, value):
        self._profiles_data = value


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    app = QApplication(sys.argv)
    app.setApplicationName("AmiCachy Hardware Audit")
    window = AuditWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
