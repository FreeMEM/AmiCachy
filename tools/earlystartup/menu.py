"""Early Startup Control menu — Amiga Workbench 3.x style (Phase 2: functional)."""

import os
import sys

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QRadioButton,
    QVBoxLayout,
    QWidget,
)

from . import config
from .theme import AMIGA_BLUE

_CUSTOM_LABEL = "Custom configuration..."


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
    """Ordered list of HDF devices with checkboxes and Up/Down buttons."""

    def __init__(self, paths: list[str], enabled: set[str] | None = None, parent=None):
        super().__init__(parent)
        self._paths = list(paths)
        # Track checked state per path; default all checked when no config
        self._checked: list[bool] = [
            (p in enabled) if enabled is not None else True
            for p in self._paths
        ]

        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(2)

        self._rebuild()

    def _rebuild(self) -> None:
        while self._layout.count():
            item = self._layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        self._checkboxes: list[QCheckBox] = []

        for i, path in enumerate(self._paths):
            row = QWidget()
            h = QHBoxLayout(row)
            h.setContentsMargins(0, 1, 0, 1)

            cb = QCheckBox()
            cb.setChecked(self._checked[i])
            cb.toggled.connect(lambda checked, idx=i: self._on_toggle(idx, checked))
            h.addWidget(cb)
            self._checkboxes.append(cb)

            num_lbl = QLabel(f"{i + 1}.")
            num_lbl.setFixedWidth(24)
            num_lbl.setStyleSheet("color: #555555;")
            h.addWidget(num_lbl)

            name_lbl = QLabel(os.path.basename(path))
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
            down_btn.setEnabled(i < len(self._paths) - 1)
            down_btn.clicked.connect(lambda _, idx=i: self._move(idx, 1))
            h.addWidget(down_btn)

            self._layout.addWidget(row)

    def _on_toggle(self, index: int, checked: bool) -> None:
        self._checked[index] = checked

    def _move(self, index: int, direction: int) -> None:
        new_index = index + direction
        if 0 <= new_index < len(self._paths):
            self._paths[index], self._paths[new_index] = (
                self._paths[new_index],
                self._paths[index],
            )
            self._checked[index], self._checked[new_index] = (
                self._checked[new_index],
                self._checked[index],
            )
            self._rebuild()

    def devices(self) -> list[str]:
        """Return only checked HDF paths in display order."""
        return [p for p, c in zip(self._paths, self._checked) if c]


# ---------------------------------------------------------------------------
# Main menu widget
# ---------------------------------------------------------------------------


class EarlyStartupMenu(QWidget):
    """Fullscreen Early Startup Control menu."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(Qt.FramelessWindowHint)

        # --- Discover real data ---
        self._rom_entries = config.scan_roms()
        self._hdf_paths = config.scan_hdfs()
        self._user_configs = config.scan_user_configs()

        # Determine initial state: preset or custom
        initial_path = config.get_initial_uae_path()
        uae_vals = config.read_uae_values(initial_path)

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

        # --- Config profile selector ---
        profile_frame = _section_frame()
        profile_inner = QVBoxLayout(profile_frame)
        profile_inner.addWidget(_section_title("Configuration Profile"))

        self._profile_combo = QComboBox()
        self._profile_combo.addItem(_CUSTOM_LABEL)
        self._profile_paths: list[str | None] = [None]  # None = custom mode
        for cfg_path in self._user_configs:
            label = os.path.basename(cfg_path)
            self._profile_combo.addItem(label)
            self._profile_paths.append(cfg_path)

        # Select the active profile
        if initial_path in self._user_configs:
            idx = self._user_configs.index(initial_path) + 1  # +1 for "Custom..."
            self._profile_combo.setCurrentIndex(idx)

        self._profile_combo.currentIndexChanged.connect(self._on_profile_changed)
        profile_inner.addWidget(self._profile_combo)
        body_layout.addWidget(profile_frame)

        # --- Editable sections (disabled in preset mode) ---

        # Section 1: Boot Device Priority
        self._boot_frame = _section_frame()
        boot_inner = QVBoxLayout(self._boot_frame)
        boot_inner.addWidget(_section_title("Boot Device Priority"))

        # Pre-select HDFs from loaded config (None = all checked)
        cfg_hardfiles = uae_vals.get("hardfiles", [])
        enabled_hdfs: set[str] | None = None
        if cfg_hardfiles:
            enabled_hdfs = set(config.parse_hardfile_paths(cfg_hardfiles))

        self._boot_list = _BootDeviceList(self._hdf_paths, enabled=enabled_hdfs)
        boot_inner.addWidget(self._boot_list)

        if not self._hdf_paths:
            no_hdf = QLabel("No .hdf files found")
            no_hdf.setStyleSheet("color: #666666; font-style: italic;")
            boot_inner.addWidget(no_hdf)

        body_layout.addWidget(self._boot_frame)

        # Section 2: Kickstart ROM + Emulator (side by side)
        mid_row = QHBoxLayout()
        mid_row.setSpacing(12)

        # Kickstart ROM
        self._rom_frame = _section_frame()
        rom_inner = QVBoxLayout(self._rom_frame)
        rom_inner.addWidget(_section_title("Kickstart ROM"))

        self._rom_combo = QComboBox()
        for entry in self._rom_entries:
            self._rom_combo.addItem(entry.label)

        # Select the ROM that matches current config
        current_rom = uae_vals.get("kickstart_rom_file", "")
        for i, entry in enumerate(self._rom_entries):
            if entry.path == current_rom:
                self._rom_combo.setCurrentIndex(i)
                break

        if not self._rom_entries:
            self._rom_combo.addItem("(no ROMs found)")
            self._rom_combo.setEnabled(False)

        rom_inner.addWidget(self._rom_combo)
        rom_inner.addStretch()
        mid_row.addWidget(self._rom_frame, stretch=1)

        # Emulator
        self._emu_frame = _section_frame()
        emu_inner = QVBoxLayout(self._emu_frame)
        emu_inner.addWidget(_section_title("Emulator"))

        self._radio_amiberry = QRadioButton("Amiberry")
        self._radio_amiberry.setChecked(True)
        emu_inner.addWidget(self._radio_amiberry)

        self._radio_winuae = QRadioButton("WinUAE (not available)")
        self._radio_winuae.setEnabled(False)
        emu_inner.addWidget(self._radio_winuae)

        self._radio_puae = QRadioButton("PUAE (not available)")
        self._radio_puae.setEnabled(False)
        emu_inner.addWidget(self._radio_puae)

        emu_inner.addStretch()
        mid_row.addWidget(self._emu_frame, stretch=1)

        body_layout.addLayout(mid_row)

        # Section 3: RAM configuration (side by side)
        ram_row = QHBoxLayout()
        ram_row.setSpacing(12)

        # Chip RAM
        self._chip_frame = _section_frame()
        chip_inner = QVBoxLayout(self._chip_frame)
        chip_inner.addWidget(_section_title("Chip RAM"))

        self._chip_combo = QComboBox()
        for label, _ in config.CHIP_RAM_OPTIONS:
            self._chip_combo.addItem(label)
        # Select current value
        current_chip = uae_vals.get("chipmem_size", 4)
        for i, (_, val) in enumerate(config.CHIP_RAM_OPTIONS):
            if val == current_chip:
                self._chip_combo.setCurrentIndex(i)
                break
        chip_inner.addWidget(self._chip_combo)
        chip_inner.addStretch()
        ram_row.addWidget(self._chip_frame, stretch=1)

        # Fast RAM
        self._fast_frame = _section_frame()
        fast_inner = QVBoxLayout(self._fast_frame)
        fast_inner.addWidget(_section_title("Fast RAM"))

        self._fast_combo = QComboBox()
        for label, _ in config.FAST_RAM_OPTIONS:
            self._fast_combo.addItem(label)
        # Select current value
        current_fast = uae_vals.get("fastmem_size", 8)
        for i, (_, val) in enumerate(config.FAST_RAM_OPTIONS):
            if val == current_fast:
                self._fast_combo.setCurrentIndex(i)
                break
        fast_inner.addWidget(self._fast_combo)
        fast_inner.addStretch()
        ram_row.addWidget(self._fast_frame, stretch=1)

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
        use_btn.clicked.connect(self._on_use)
        footer_layout.addWidget(use_btn)

        save_btn = QPushButton("Save")
        save_btn.setObjectName("primaryButton")
        save_btn.clicked.connect(self._on_save)
        footer_layout.addWidget(save_btn)

        root.addWidget(footer)

        # Collect editable widgets for enable/disable toggling
        self._edit_widgets = [
            self._boot_frame, self._rom_frame, self._emu_frame,
            self._chip_frame, self._fast_frame,
        ]

        # Apply initial mode (preset vs custom)
        self._on_profile_changed(self._profile_combo.currentIndex())

    # --- Mode switching ---

    def _is_custom_mode(self) -> bool:
        return self._profile_paths[self._profile_combo.currentIndex()] is None

    def _on_profile_changed(self, index: int) -> None:
        custom = self._profile_paths[index] is None
        for w in self._edit_widgets:
            w.setEnabled(custom)

    # --- Actions ---

    def _on_cancel(self) -> None:
        """Close without applying — amilaunch.sh uses default config."""
        sys.exit(1)

    def _gather_settings(self) -> tuple[config.RomEntry, list[str], int, int]:
        """Extract current ROM, HDFs, chipmem, fastmem from widgets."""
        rom_idx = self._rom_combo.currentIndex()
        if self._rom_entries and 0 <= rom_idx < len(self._rom_entries):
            rom = self._rom_entries[rom_idx]
        else:
            rom = config.RomEntry("AROS", config.AROS_ROM, config.AROS_EXT)

        hdfs = self._boot_list.devices()

        chip_idx = self._chip_combo.currentIndex()
        chipmem = config.CHIP_RAM_OPTIONS[chip_idx][1] if 0 <= chip_idx < len(config.CHIP_RAM_OPTIONS) else 4

        fast_idx = self._fast_combo.currentIndex()
        fastmem = config.FAST_RAM_OPTIONS[fast_idx][1] if 0 <= fast_idx < len(config.FAST_RAM_OPTIONS) else 8

        return rom, hdfs, chipmem, fastmem

    def _selected_preset(self) -> str | None:
        """Return the preset .uae path, or None if in custom mode."""
        return self._profile_paths[self._profile_combo.currentIndex()]

    def _on_use(self) -> None:
        """Apply config for this session only and exit 0."""
        preset = self._selected_preset()
        if preset:
            config.write_session_ref(preset)
        else:
            rom, hdfs, chipmem, fastmem = self._gather_settings()
            config.write_session_uae(rom, hdfs, chipmem, fastmem)
        sys.exit(0)

    def _on_save(self) -> None:
        """Save config as boot default and apply now."""
        preset = self._selected_preset()
        if preset:
            config.write_session_ref(preset)
            err = config.write_boot_ref(preset)
        else:
            rom, hdfs, chipmem, fastmem = self._gather_settings()
            err = config.write_saved_uae(rom, hdfs, chipmem, fastmem)
        if err:
            print(f"Warning: persistent save failed: {err}", file=sys.stderr)
        sys.exit(0)
