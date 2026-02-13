"""Early Startup Control menu — Amiga Workbench 3.x style (Phase 1: UI shell)."""

import sys

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QRadioButton,
    QVBoxLayout,
    QWidget,
)

from .theme import AMIGA_BLUE


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _section_frame() -> QFrame:
    """Amiga-style recessed section frame (inset bevel)."""
    frame = QFrame()
    frame.setObjectName("amigaSection")
    return frame


def _section_title(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setObjectName("sectionTitle")
    font = QFont()
    font.setPointSize(13)
    font.setBold(True)
    lbl.setFont(font)
    return lbl


# ---------------------------------------------------------------------------
# Boot device list widget
# ---------------------------------------------------------------------------


class _BootDeviceList(QWidget):
    """Ordered list of HDF devices with Up/Down buttons."""

    def __init__(self, devices: list[str], parent=None):
        super().__init__(parent)
        self._devices = list(devices)

        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(2)

        self._rebuild()

    def _rebuild(self) -> None:
        while self._layout.count():
            item = self._layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        for i, name in enumerate(self._devices):
            row = QWidget()
            h = QHBoxLayout(row)
            h.setContentsMargins(0, 1, 0, 1)

            num_lbl = QLabel(f"{i + 1}.")
            num_lbl.setFixedWidth(24)
            num_lbl.setStyleSheet("color: #555555;")
            h.addWidget(num_lbl)

            name_lbl = QLabel(name)
            h.addWidget(name_lbl, stretch=1)

            _sm_btn = (
                "padding: 2px 4px; font-size: 12px;"
            )

            up_btn = QPushButton("Up")
            up_btn.setFixedSize(40, 26)
            up_btn.setStyleSheet(_sm_btn)
            up_btn.setEnabled(i > 0)
            up_btn.clicked.connect(lambda _, idx=i: self._move(idx, -1))
            h.addWidget(up_btn)

            down_btn = QPushButton("Dn")
            down_btn.setFixedSize(40, 26)
            down_btn.setStyleSheet(_sm_btn)
            down_btn.setEnabled(i < len(self._devices) - 1)
            down_btn.clicked.connect(lambda _, idx=i: self._move(idx, 1))
            h.addWidget(down_btn)

            self._layout.addWidget(row)

    def _move(self, index: int, direction: int) -> None:
        new_index = index + direction
        if 0 <= new_index < len(self._devices):
            self._devices[index], self._devices[new_index] = (
                self._devices[new_index],
                self._devices[index],
            )
            self._rebuild()


# ---------------------------------------------------------------------------
# Main menu widget
# ---------------------------------------------------------------------------


class EarlyStartupMenu(QWidget):
    """Fullscreen Early Startup Control menu (Phase 1: placeholder data)."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(Qt.FramelessWindowHint)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # --- Header (Amiga screen title bar) ---
        header = QWidget()
        header.setFixedHeight(48)
        header.setStyleSheet(
            f"background-color: {AMIGA_BLUE};"
        )
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(16, 0, 16, 0)

        title = QLabel("AmiCachy Early Startup Control")
        title.setObjectName("headerTitle")
        header_layout.addWidget(title)
        header_layout.addStretch()

        root.addWidget(header)

        # --- Body ---
        body = QWidget()
        body_layout = QVBoxLayout(body)
        body_layout.setContentsMargins(24, 16, 24, 16)
        body_layout.setSpacing(12)

        # Subtitle
        subtitle = QLabel("(press F5 during boot to open this menu)")
        subtitle.setAlignment(Qt.AlignCenter)
        subtitle.setStyleSheet("color: #333333; font-size: 12px;")
        body_layout.addWidget(subtitle)

        # Section 1: Boot Device Priority
        boot_frame = _section_frame()
        boot_inner = QVBoxLayout(boot_frame)
        boot_inner.addWidget(_section_title("Boot Device Priority"))

        self._boot_list = _BootDeviceList([
            "System.hdf",
            "Games.hdf",
            "Work.hdf",
        ])
        boot_inner.addWidget(self._boot_list)
        body_layout.addWidget(boot_frame)

        # Section 2: Kickstart ROM + Emulator (side by side)
        mid_row = QHBoxLayout()
        mid_row.setSpacing(12)

        # Kickstart ROM
        rom_frame = _section_frame()
        rom_inner = QVBoxLayout(rom_frame)
        rom_inner.addWidget(_section_title("Kickstart ROM"))

        self._rom_combo = QComboBox()
        self._rom_combo.addItems([
            "AROS 3.1.4 (built-in)",
            "Kick 1.3 (A500)",
            "Kick 3.1 (A1200)",
            "Kick 3.2.2 (A1200)",
        ])
        rom_inner.addWidget(self._rom_combo)
        rom_inner.addStretch()
        mid_row.addWidget(rom_frame, stretch=1)

        # Emulator
        emu_frame = _section_frame()
        emu_inner = QVBoxLayout(emu_frame)
        emu_inner.addWidget(_section_title("Emulator"))

        self._radio_amiberry = QRadioButton("Amiberry")
        self._radio_amiberry.setChecked(True)
        emu_inner.addWidget(self._radio_amiberry)

        self._radio_puae = QRadioButton("PUAE (not available)")
        self._radio_puae.setEnabled(False)
        emu_inner.addWidget(self._radio_puae)

        emu_inner.addStretch()
        mid_row.addWidget(emu_frame, stretch=1)

        body_layout.addLayout(mid_row)

        # Section 3: RAM configuration (side by side)
        ram_row = QHBoxLayout()
        ram_row.setSpacing(12)

        # Chip RAM
        chip_frame = _section_frame()
        chip_inner = QVBoxLayout(chip_frame)
        chip_inner.addWidget(_section_title("Chip RAM"))

        self._chip_combo = QComboBox()
        self._chip_combo.addItems(["512 KB", "1 MB", "2 MB"])
        self._chip_combo.setCurrentIndex(2)
        chip_inner.addWidget(self._chip_combo)
        chip_inner.addStretch()
        ram_row.addWidget(chip_frame, stretch=1)

        # Fast RAM
        fast_frame = _section_frame()
        fast_inner = QVBoxLayout(fast_frame)
        fast_inner.addWidget(_section_title("Fast RAM"))

        self._fast_combo = QComboBox()
        self._fast_combo.addItems(["None", "2 MB", "4 MB", "8 MB"])
        self._fast_combo.setCurrentIndex(3)
        fast_inner.addWidget(self._fast_combo)
        fast_inner.addStretch()
        ram_row.addWidget(fast_frame, stretch=1)

        body_layout.addLayout(ram_row)

        body_layout.addStretch()
        root.addWidget(body, stretch=1)

        # --- Footer (Amiga-style bottom bar) ---
        footer = QWidget()
        footer.setFixedHeight(52)
        footer.setStyleSheet(
            "border-top: 2px solid #000000;"
        )
        footer_layout = QHBoxLayout(footer)
        footer_layout.setContentsMargins(16, 8, 16, 8)

        cancel_btn = QPushButton("Cancel")
        cancel_btn.clicked.connect(self._on_cancel)
        footer_layout.addWidget(cancel_btn)

        footer_layout.addStretch()

        use_btn = QPushButton("Use")
        use_btn.setObjectName("primaryButton")
        use_btn.clicked.connect(self._on_use)
        footer_layout.addWidget(use_btn)

        root.addWidget(footer)

    def _on_cancel(self) -> None:
        """Close without applying — Phase 1: just exit."""
        sys.exit(0)

    def _on_use(self) -> None:
        """Apply settings and close — Phase 1: just exit."""
        sys.exit(0)
