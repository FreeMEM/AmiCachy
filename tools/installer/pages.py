"""Wizard pages for the AmiCachy installer."""

import subprocess

from PySide6.QtCore import Qt, Signal, QTimer
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QSpacerItem,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from .resources import BOOT_ENTRIES, PROFILE_DISPLAY, WELCOME_TEXT
from .slideshow import SlideshowWidget
from .theme import STATUS_COLORS
from .workers import (
    DiskScanWorker,
    HardwareAuditWorker,
    InstallWorker,
    InstallerState,
)


# ---------------------------------------------------------------------------
# Helper widgets
# ---------------------------------------------------------------------------


def _page_title(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setObjectName("pageTitle")
    return lbl


def _subtitle(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setObjectName("subtitle")
    lbl.setWordWrap(True)
    return lbl


def _info_label(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setWordWrap(True)
    lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
    return lbl


def _section_label(text: str) -> QLabel:
    lbl = QLabel(text)
    font = QFont()
    font.setPointSize(13)
    font.setBold(True)
    lbl.setFont(font)
    lbl.setContentsMargins(0, 12, 0, 4)
    return lbl


class HeaderBar(QWidget):
    """Top bar with step title and progress dots."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(60)
        self.setStyleSheet("background-color: #0d1b2a; padding: 0 16px;")

        layout = QHBoxLayout(self)
        layout.setContentsMargins(20, 0, 20, 0)

        self._title = QLabel("AmiCachy Setup")
        self._title.setObjectName("headerTitle")
        layout.addWidget(self._title)

        layout.addStretch()

        self._dots_layout = QHBoxLayout()
        self._dots_layout.setSpacing(8)
        self._dots: list[QLabel] = []
        layout.addLayout(self._dots_layout)

    def set_title(self, title: str) -> None:
        self._title.setText(title)

    def set_progress(self, current: int, total: int) -> None:
        # Clear old dots
        for dot in self._dots:
            dot.deleteLater()
        self._dots.clear()

        for i in range(total):
            dot = QLabel("\u25cf")
            if i <= current:
                dot.setStyleSheet("color: #e94560; font-size: 14px;")
            else:
                dot.setStyleSheet("color: #333; font-size: 14px;")
            self._dots.append(dot)
            self._dots_layout.addWidget(dot)


class FooterBar(QWidget):
    """Bottom bar with Back / Next navigation buttons."""

    back_clicked = Signal()
    next_clicked = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(60)
        self.setStyleSheet("background-color: #0d1b2a;")

        layout = QHBoxLayout(self)
        layout.setContentsMargins(20, 8, 20, 8)

        self._back_btn = QPushButton("Back")
        self._back_btn.clicked.connect(self.back_clicked.emit)
        layout.addWidget(self._back_btn)

        layout.addStretch()

        self._next_btn = QPushButton("Next")
        self._next_btn.setObjectName("primaryButton")
        self._next_btn.clicked.connect(self.next_clicked.emit)
        layout.addWidget(self._next_btn)

    def set_back_visible(self, visible: bool) -> None:
        self._back_btn.setVisible(visible)

    def set_next_visible(self, visible: bool) -> None:
        self._next_btn.setVisible(visible)

    def set_next_text(self, text: str) -> None:
        self._next_btn.setText(text)

    def set_next_enabled(self, enabled: bool) -> None:
        self._next_btn.setEnabled(enabled)

    def set_navigation_visible(self, visible: bool) -> None:
        self._back_btn.setVisible(visible)
        self._next_btn.setVisible(visible)


# ---------------------------------------------------------------------------
# Page 0: Welcome
# ---------------------------------------------------------------------------


class WelcomePage(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        layout.setSpacing(16)

        title = QLabel("Welcome to AmiCachy")
        title.setAlignment(Qt.AlignCenter)
        font = QFont()
        font.setPointSize(28)
        font.setBold(True)
        title.setFont(font)
        title.setStyleSheet("color: white;")
        layout.addWidget(title)

        subtitle = QLabel("Your dedicated Amiga workstation")
        subtitle.setAlignment(Qt.AlignCenter)
        subtitle.setStyleSheet("color: #e94560; font-size: 16px;")
        layout.addWidget(subtitle)

        layout.addSpacerItem(QSpacerItem(0, 20))

        info = QLabel(WELCOME_TEXT)
        info.setAlignment(Qt.AlignCenter)
        info.setWordWrap(True)
        info.setMaximumWidth(600)
        info.setStyleSheet("font-size: 15px; line-height: 1.6;")
        layout.addWidget(info, alignment=Qt.AlignCenter)


# ---------------------------------------------------------------------------
# Page 1: Hardware Audit
# ---------------------------------------------------------------------------


class HardwareAuditPage(QWidget):
    """Runs hardware detection and benchmark, displays results."""

    audit_complete = Signal()

    def __init__(self, state: InstallerState, parent=None):
        super().__init__(parent)
        self.state = state
        self._worker: HardwareAuditWorker | None = None
        self._done = False

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        layout.addWidget(_page_title("Hardware Check"))

        self._status_label = _info_label("Preparing hardware analysis...")
        layout.addWidget(self._status_label)

        self._progress = QProgressBar()
        self._progress.setRange(0, 0)  # indeterminate
        layout.addWidget(self._progress)

        # Results area (hidden until audit completes)
        self._results_widget = QWidget()
        self._results_layout = QVBoxLayout(self._results_widget)
        self._results_layout.setContentsMargins(0, 0, 0, 0)
        self._results_widget.setVisible(False)
        layout.addWidget(self._results_widget)

        layout.addStretch()

    @property
    def is_done(self) -> bool:
        return self._done

    def start_audit(self) -> None:
        if self._done:
            return
        self._worker = HardwareAuditWorker()
        self._worker.progress.connect(self._on_progress)
        self._worker.finished.connect(self._on_finished)
        self._worker.start()

    def _on_progress(self, msg: str) -> None:
        self._status_label.setText(msg)

    def _on_finished(self, result: dict) -> None:
        self._done = True
        self.state.audit_result = result
        self._progress.setVisible(False)
        self._status_label.setText("Hardware analysis complete.")
        self._results_widget.setVisible(True)

        lay = self._results_layout

        # CPU section
        lay.addWidget(_section_label("CPU"))
        cpu = result["cpu"]
        lay.addWidget(_info_label(f"Model: {cpu['model']}"))
        lay.addWidget(_info_label(
            f"Cores: {cpu['cores']}  |  Threads: {cpu['threads']}"
        ))
        lay.addWidget(_info_label(f"Architecture level: {cpu['arch_level']}"))

        # Virtualization
        lay.addWidget(_section_label("Virtualization"))
        virt = result["virtualization"]
        if virt["intel_vtx"]:
            virt_text = "Intel VT-x (vmx) detected."
        elif virt["amd_svm"]:
            virt_text = "AMD-V (svm) detected."
        else:
            virt_text = "No hardware virtualization detected."
        virt_lbl = _info_label(virt_text)
        if not virt["supported"]:
            virt_lbl.setStyleSheet("color: #c0392b; font-weight: bold;")
        lay.addWidget(virt_lbl)

        # Benchmark
        lay.addWidget(_section_label("Performance"))
        bench = result["benchmark"]
        lay.addWidget(_info_label(
            f"Score: {int(bench['rate']):,} iter/s  \u2014  "
            f"{bench['x5000_ratio']}x AmigaOne X5000 reference"
        ))

        # Profile recommendations
        lay.addWidget(_section_label("Profile Compatibility"))
        for p in result["profiles"]:
            frame = QFrame()
            frame.setFrameShape(QFrame.StyledPanel)
            color = STATUS_COLORS.get(p["status"], "#888")
            frame.setStyleSheet(
                f"QFrame {{ border-left: 4px solid {color}; padding: 6px; }}"
            )
            h = QHBoxLayout(frame)
            h.setContentsMargins(8, 4, 8, 4)
            dot = QLabel("\u25cf")
            dot.setStyleSheet(f"color: {color}; font-size: 18px;")
            dot.setFixedWidth(24)
            h.addWidget(dot)
            h.addWidget(_info_label(f"<b>{p['name']}</b> \u2014 {p['note']}"))
            lay.addWidget(frame)

        self.audit_complete.emit()


# ---------------------------------------------------------------------------
# Page 2: Disk Select
# ---------------------------------------------------------------------------


class DiskCard(QFrame):
    """Clickable card representing a disk drive."""

    clicked = Signal(str)  # device path

    def __init__(self, disk: dict, parent=None):
        super().__init__(parent)
        self.device = disk["device"]
        self.model = disk.get("model", "Unknown drive")
        self.size = disk.get("size", 0)
        self._selected = False
        self.setCursor(Qt.PointingHandCursor)
        self.setObjectName("diskCard")
        self.setFixedHeight(70)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(16, 8, 16, 8)

        left = QVBoxLayout()
        name_lbl = QLabel(f"<b>{disk['model']}</b>")
        name_lbl.setStyleSheet("font-size: 15px;")
        left.addWidget(name_lbl)

        detail = f"/dev/{disk['name']}  \u2022  {disk['transport']}"
        left.addWidget(_info_label(detail))
        layout.addLayout(left, stretch=1)

        size_lbl = QLabel(disk["size_display"])
        size_lbl.setStyleSheet("font-size: 16px; font-weight: bold; color: #e94560;")
        layout.addWidget(size_lbl)

    def mousePressEvent(self, event):
        self.clicked.emit(self.device)
        super().mousePressEvent(event)

    def set_selected(self, selected: bool) -> None:
        self._selected = selected
        self.setObjectName("diskCardSelected" if selected else "diskCard")
        self.setStyleSheet(self.styleSheet())  # force re-apply
        self.style().unpolish(self)
        self.style().polish(self)


class DiskSelectPage(QWidget):
    """Lists available disks for the user to select."""

    disk_selected = Signal(str)

    def __init__(self, state: InstallerState, parent=None):
        super().__init__(parent)
        self.state = state
        self._worker: DiskScanWorker | None = None
        self._cards: list[DiskCard] = []

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        layout.addWidget(_page_title("Select Target Drive"))
        layout.addWidget(_subtitle(
            "Choose the drive where AmiCachy will be installed. "
            "All data on the selected drive will be erased."
        ))

        warning = QLabel(
            "\u26a0  This operation is irreversible. "
            "Make sure you select the correct drive."
        )
        warning.setObjectName("warning")
        warning.setWordWrap(True)
        layout.addWidget(warning)

        # Scrollable disk list
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        self._disk_container = QWidget()
        self._disk_layout = QVBoxLayout(self._disk_container)
        self._disk_layout.setAlignment(Qt.AlignTop)
        scroll.setWidget(self._disk_container)
        layout.addWidget(scroll, stretch=1)

        # Refresh button
        refresh_btn = QPushButton("Refresh")
        refresh_btn.setFixedWidth(120)
        refresh_btn.clicked.connect(self.scan_disks)
        layout.addWidget(refresh_btn)

        # Status
        self._status = _info_label("")
        layout.addWidget(self._status)

    def scan_disks(self) -> None:
        self._status.setText("Scanning drives...")
        self._clear_cards()
        self._worker = DiskScanWorker()
        self._worker.finished.connect(self._on_scan_done)
        self._worker.start()

    def _clear_cards(self) -> None:
        for card in self._cards:
            card.deleteLater()
        self._cards.clear()

    def _on_scan_done(self, disks: list[dict]) -> None:
        self._clear_cards()
        if not disks:
            self._status.setText(
                "No suitable drives found. "
                "Drives must be at least 20 GB, non-removable, and writable."
            )
            return
        self._status.setText(f"{len(disks)} drive(s) found.")
        for disk in disks:
            card = DiskCard(disk)
            card.clicked.connect(self._on_disk_clicked)
            self._disk_layout.addWidget(card)
            self._cards.append(card)

    def _on_disk_clicked(self, device: str) -> None:
        self.state.target_device = device
        for card in self._cards:
            selected = card.device == device
            card.set_selected(selected)
            if selected:
                self.state.target_device_model = card.model
                self.state.target_device_size = card.size
        self.disk_selected.emit(device)


# ---------------------------------------------------------------------------
# Page 3: Profile Select
# ---------------------------------------------------------------------------


class ProfileSelectPage(QWidget):
    """Checkboxes for selecting which boot profiles to install."""

    selection_changed = Signal()

    def __init__(self, state: InstallerState, parent=None):
        super().__init__(parent)
        self.state = state
        self._checkboxes: dict[str, QCheckBox] = {}
        self._status_dots: dict[str, QLabel] = {}

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        layout.addWidget(_page_title("Select Boot Modes"))
        layout.addWidget(_subtitle(
            "Choose which modes to install. "
            "At least one must be selected."
        ))

        # Profile checkboxes
        profiles_order = ["classic_68k", "ppc_nitro", "dev_station"]
        for profile_id in profiles_order:
            info = PROFILE_DISPLAY[profile_id]
            frame = QFrame()
            frame.setFrameShape(QFrame.StyledPanel)
            frame.setStyleSheet(
                "QFrame { background-color: #16213e; border-radius: 8px; "
                "padding: 12px; margin: 4px 0; }"
            )
            h = QHBoxLayout(frame)

            cb = QCheckBox()
            cb.setChecked(profile_id == "classic_68k")
            cb.stateChanged.connect(self._on_checkbox_changed)
            self._checkboxes[profile_id] = cb
            h.addWidget(cb)

            text_layout = QVBoxLayout()
            name_lbl = QLabel(f"<b>{info['name']}</b>")
            name_lbl.setStyleSheet("font-size: 15px;")
            text_layout.addWidget(name_lbl)
            desc_lbl = _info_label(info["description"])
            text_layout.addWidget(desc_lbl)
            h.addLayout(text_layout, stretch=1)

            # Status dot (colored after audit)
            dot = QLabel("\u25cf")
            dot.setFixedWidth(24)
            dot.setStyleSheet("color: #888; font-size: 18px;")
            self._status_dots[profile_id] = dot
            h.addWidget(dot)

            layout.addWidget(frame)

        layout.addSpacerItem(QSpacerItem(0, 16))

        # Default boot selector
        default_layout = QHBoxLayout()
        default_layout.addWidget(QLabel("Default boot mode:"))
        self._default_combo = QComboBox()
        for profile_id in profiles_order:
            self._default_combo.addItem(
                PROFILE_DISPLAY[profile_id]["name"], profile_id
            )
        self._default_combo.currentIndexChanged.connect(self._on_default_changed)
        default_layout.addWidget(self._default_combo)
        default_layout.addStretch()
        layout.addLayout(default_layout)

        layout.addStretch()

    def update_from_audit(self) -> None:
        """Disable red profiles and color status dots from audit results."""
        profiles = self.state.audit_result.get("profiles", [])
        profile_map = {p["name"]: p for p in profiles}

        for profile_id, cb in self._checkboxes.items():
            display_name = PROFILE_DISPLAY[profile_id]["name"]
            p = profile_map.get(display_name, {})
            status = p.get("status", "green")

            # Color the status dot
            dot = self._status_dots.get(profile_id)
            if dot:
                color = STATUS_COLORS.get(status, "#888")
                dot.setStyleSheet(f"color: {color}; font-size: 18px;")

            if status == "red":
                cb.setChecked(False)
                cb.setEnabled(False)
                cb.setToolTip(p.get("note", "Not compatible with your hardware."))

    def _on_checkbox_changed(self) -> None:
        self.state.selected_profiles = [
            pid for pid, cb in self._checkboxes.items() if cb.isChecked()
        ]
        self.selection_changed.emit()

    def _on_default_changed(self, index: int) -> None:
        self.state.default_profile = self._default_combo.itemData(index)

    @property
    def has_selection(self) -> bool:
        return any(cb.isChecked() for cb in self._checkboxes.values())


# ---------------------------------------------------------------------------
# Page 4: Confirm
# ---------------------------------------------------------------------------


class ConfirmPage(QWidget):
    """Final summary before installation begins."""

    def __init__(self, state: InstallerState, parent=None):
        super().__init__(parent)
        self.state = state

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        layout.addWidget(_page_title("Ready to Install"))

        self._summary = QLabel()
        self._summary.setWordWrap(True)
        self._summary.setStyleSheet("font-size: 14px; line-height: 1.6;")
        layout.addWidget(self._summary)

        layout.addStretch()

        warning = QLabel(
            "\u26a0  Pressing 'Begin Installation' will erase all data "
            "on the selected drive. This cannot be undone."
        )
        warning.setObjectName("warning")
        warning.setWordWrap(True)
        layout.addWidget(warning)

    def refresh_summary(self) -> None:
        s = self.state
        cpu_model = s.audit_result.get("cpu", {}).get("model", "Unknown")
        arch = s.audit_result.get("cpu", {}).get("arch_level", "Unknown")

        profiles_text = ""
        for pid in s.selected_profiles:
            name = PROFILE_DISPLAY.get(pid, {}).get("name", pid)
            default = " (default)" if pid == s.default_profile else ""
            profiles_text += f"  \u2022 {name}{default}\n"

        size_gb = s.target_device_size / (1024 ** 3) if s.target_device_size else 0

        text = (
            f"<b>Target drive:</b> {s.target_device}"
            f" ({s.target_device_model}, {size_gb:.1f} GB)\n\n"
            f"<b>Partitions:</b>\n"
            f"  \u2022 EFI: 512 MB (FAT32)\n"
            f"  \u2022 System: ~60% of disk (ext4, label: AMICACHY)\n"
            f"  \u2022 Amiga Data: ~40% of disk (ext4)\n\n"
            f"<b>Boot modes:</b>\n{profiles_text}\n"
            f"<b>Hardware:</b> {cpu_model} ({arch})"
        )
        self._summary.setText(text)


# ---------------------------------------------------------------------------
# Page 5: Install
# ---------------------------------------------------------------------------


class InstallPage(QWidget):
    """Installation progress with slideshow and log viewer."""

    install_finished = Signal(bool, str)

    def __init__(self, state: InstallerState, parent=None):
        super().__init__(parent)
        self.state = state
        self._worker: InstallWorker | None = None

        layout = QVBoxLayout(self)
        layout.setSpacing(8)

        layout.addWidget(_page_title("Installing"))

        # Slideshow
        self._slideshow = SlideshowWidget()
        self._slideshow.setMinimumHeight(200)
        layout.addWidget(self._slideshow, stretch=3)

        # Step label
        self._step_label = QLabel("Preparing...")
        self._step_label.setStyleSheet(
            "font-size: 15px; font-weight: bold; padding: 4px 0;"
        )
        layout.addWidget(self._step_label)

        # Progress bar
        self._progress = QProgressBar()
        self._progress.setRange(0, 100)
        self._progress.setValue(0)
        layout.addWidget(self._progress)

        # Toggle details button
        self._details_btn = QPushButton("Show Details")
        self._details_btn.setFixedWidth(140)
        self._details_btn.clicked.connect(self._toggle_details)
        layout.addWidget(self._details_btn)

        # Log viewer (hidden by default)
        self._log_view = QPlainTextEdit()
        self._log_view.setReadOnly(True)
        self._log_view.setMaximumHeight(200)
        self._log_view.setVisible(False)
        layout.addWidget(self._log_view, stretch=1)

    def start_install(self) -> None:
        self._slideshow.start()
        self._worker = InstallWorker(self.state)
        self._worker.step_changed.connect(self._on_step_changed)
        self._worker.log_line.connect(self._on_log_line)
        self._worker.finished.connect(self._on_finished)
        self._worker.start()

    def _on_step_changed(self, desc: str, progress: int) -> None:
        self._step_label.setText(desc)
        self._progress.setValue(progress)

    def _on_log_line(self, line: str) -> None:
        self._log_view.appendPlainText(line)
        # Auto-scroll to bottom
        sb = self._log_view.verticalScrollBar()
        sb.setValue(sb.maximum())

    def _on_finished(self, success: bool, error: str) -> None:
        self._slideshow.stop()
        self.install_finished.emit(success, error)

    def _toggle_details(self) -> None:
        visible = not self._log_view.isVisible()
        self._log_view.setVisible(visible)
        self._details_btn.setText("Hide Details" if visible else "Show Details")


# ---------------------------------------------------------------------------
# Page 6: Finish
# ---------------------------------------------------------------------------


class FinishPage(QWidget):
    """Success screen with reboot button."""

    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        layout.setSpacing(16)

        check = QLabel("\u2713")
        check.setAlignment(Qt.AlignCenter)
        check.setStyleSheet("color: #27ae60; font-size: 72px;")
        layout.addWidget(check)

        title = QLabel("Installation Complete!")
        title.setAlignment(Qt.AlignCenter)
        font = QFont()
        font.setPointSize(24)
        font.setBold(True)
        title.setFont(font)
        title.setStyleSheet("color: white;")
        layout.addWidget(title)

        info = QLabel(
            "Your Amiga workstation is ready.\n"
            "Remove the installation media and press Reboot."
        )
        info.setAlignment(Qt.AlignCenter)
        info.setWordWrap(True)
        info.setStyleSheet("font-size: 15px;")
        layout.addWidget(info)

        layout.addSpacerItem(QSpacerItem(0, 24))

        reboot_btn = QPushButton("Reboot")
        reboot_btn.setObjectName("primaryButton")
        reboot_btn.setFixedWidth(200)
        reboot_btn.clicked.connect(self._on_reboot)
        layout.addWidget(reboot_btn, alignment=Qt.AlignCenter)

    def _on_reboot(self) -> None:
        subprocess.run(["systemctl", "reboot"], check=False)


# ---------------------------------------------------------------------------
# Page 5b: Error display (overlay on InstallPage)
# ---------------------------------------------------------------------------


class ErrorPage(QWidget):
    """Shown when installation fails."""

    retry_clicked = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        layout.setSpacing(16)

        icon = QLabel("\u2717")
        icon.setAlignment(Qt.AlignCenter)
        icon.setStyleSheet("color: #c0392b; font-size: 64px;")
        layout.addWidget(icon)

        title = QLabel("Installation Failed")
        title.setAlignment(Qt.AlignCenter)
        font = QFont()
        font.setPointSize(20)
        font.setBold(True)
        title.setFont(font)
        title.setStyleSheet("color: #c0392b;")
        layout.addWidget(title)

        self._error_label = QLabel()
        self._error_label.setAlignment(Qt.AlignCenter)
        self._error_label.setWordWrap(True)
        self._error_label.setMaximumWidth(600)
        layout.addWidget(self._error_label)

        self._log_view = QPlainTextEdit()
        self._log_view.setReadOnly(True)
        self._log_view.setMaximumHeight(150)
        layout.addWidget(self._log_view)

        btn_layout = QHBoxLayout()
        retry_btn = QPushButton("Retry")
        retry_btn.setObjectName("primaryButton")
        retry_btn.clicked.connect(self.retry_clicked.emit)
        btn_layout.addWidget(retry_btn)
        layout.addLayout(btn_layout)

    def set_error(self, message: str, log_text: str = "") -> None:
        self._error_label.setText(message)
        if log_text:
            self._log_view.setPlainText(log_text)


# ---------------------------------------------------------------------------
# Main Wizard
# ---------------------------------------------------------------------------


class InstallerWizard(QWidget):
    """Frameless fullscreen wizard orchestrating all pages."""

    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.FramelessWindowHint)
        self.state = InstallerState()

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Header
        self._header = HeaderBar()
        root.addWidget(self._header)

        # Stacked pages
        self._stack = QStackedWidget()

        self._welcome = WelcomePage()
        self._audit = HardwareAuditPage(self.state)
        self._disk = DiskSelectPage(self.state)
        self._profiles = ProfileSelectPage(self.state)
        self._confirm = ConfirmPage(self.state)
        self._install = InstallPage(self.state)
        self._finish = FinishPage()
        self._error = ErrorPage()

        self._pages: list[QWidget] = [
            self._welcome,
            self._audit,
            self._disk,
            self._profiles,
            self._confirm,
            self._install,
            self._finish,
            self._error,
        ]
        for page in self._pages:
            self._stack.addWidget(page)
        root.addWidget(self._stack, stretch=1)

        # Footer
        self._footer = FooterBar()
        self._footer.back_clicked.connect(self._go_back)
        self._footer.next_clicked.connect(self._go_next)
        root.addWidget(self._footer)

        # Connect signals
        self._audit.audit_complete.connect(self._on_audit_complete)
        self._disk.disk_selected.connect(self._on_disk_selected)
        self._profiles.selection_changed.connect(self._on_profile_changed)
        self._install.install_finished.connect(self._on_install_finished)
        self._error.retry_clicked.connect(self._on_retry)

        self._current = 0
        self._update_ui()

    # -- Navigation --

    def _go_next(self) -> None:
        if self._current < 6:
            self._current += 1
            self._stack.setCurrentIndex(self._current)
            self._on_page_entered(self._current)
            self._update_ui()

    def _go_back(self) -> None:
        if self._current > 0:
            self._current -= 1
            self._stack.setCurrentIndex(self._current)
            self._update_ui()

    def _on_page_entered(self, index: int) -> None:
        page = self._pages[index]
        if isinstance(page, HardwareAuditPage):
            self._footer.set_next_enabled(page.is_done)
            page.start_audit()
        elif isinstance(page, DiskSelectPage):
            page.scan_disks()
            self._footer.set_next_enabled(bool(self.state.target_device))
        elif isinstance(page, ProfileSelectPage):
            page.update_from_audit()
            self._footer.set_next_enabled(page.has_selection)
        elif isinstance(page, ConfirmPage):
            page.refresh_summary()
        elif isinstance(page, InstallPage):
            self._footer.set_navigation_visible(False)
            page.start_install()

    def _update_ui(self) -> None:
        titles = [
            "Welcome",
            "Hardware Check",
            "Select Drive",
            "Select Modes",
            "Confirm",
            "Installing",
            "Complete",
            "Error",
        ]
        self._header.set_title(titles[self._current])
        self._header.set_progress(self._current, 7)

        # Back button: visible on pages 1-4
        self._footer.set_back_visible(0 < self._current < 5)

        # Next button text
        if self._current == 4:
            self._footer.set_next_text("Begin Installation")
        else:
            self._footer.set_next_text("Next")

        # Next visibility
        self._footer.set_next_visible(self._current < 5)

    # -- Signal handlers --

    def _on_audit_complete(self) -> None:
        self._footer.set_next_enabled(True)

    def _on_disk_selected(self, device: str) -> None:
        # Store device info from lsblk data
        for card in self._disk._cards:
            if card.device == device:
                self.state.target_device = device
        self._footer.set_next_enabled(True)

    def _on_profile_changed(self) -> None:
        self._footer.set_next_enabled(self._profiles.has_selection)

    def _on_install_finished(self, success: bool, error: str) -> None:
        if success:
            self._current = 6  # FinishPage
            self._stack.setCurrentIndex(6)
            self._footer.set_navigation_visible(False)
            self._update_ui()
        else:
            self._stack.setCurrentIndex(7)  # ErrorPage
            self._error.set_error(error)
            self._footer.set_navigation_visible(False)

    def _on_retry(self) -> None:
        # Go back to disk selection
        self._current = 2
        self._stack.setCurrentIndex(2)
        self._footer.set_navigation_visible(True)
        self._update_ui()
