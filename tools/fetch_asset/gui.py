"""Qt frontend — Asset Library window.

Reuses the Amiga Workbench theme defined in earlystartup/theme.py so that
the asset manager visually matches the Early Startup Control screen.
"""

from __future__ import annotations

import html
import subprocess
import sys
from pathlib import Path

from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QAction, QFont
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMenu,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSplitter,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from . import catalog as cat_mod
from . import installer, presets, state

try:
    # earlystartup/ and fetch_asset/ live side by side under
    # /usr/share/amicachy/tools so this absolute import works at runtime.
    from earlystartup.theme import AMIGA_BLUE, AMIGA_STYLESHEET
except ImportError:  # pragma: no cover — dev fallback
    AMIGA_BLUE = "#3b67a2"
    AMIGA_STYLESHEET = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _fmt_size(n: int) -> str:
    f = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or unit == "TB":
            return f"{f:.1f} {unit}"
        f /= 1024
    return f"{f:.1f} TB"


# ---------------------------------------------------------------------------
# License acceptance dialog
# ---------------------------------------------------------------------------


class LicenseDialog(QDialog):
    """Blocking pre-install consent dialog. Continue stays disabled until
    the user ticks the acceptance checkbox."""

    def __init__(self, asset, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"License — {asset.name}")
        self.resize(620, 420)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 16, 16, 16)
        layout.setSpacing(10)

        title = QLabel(asset.name)
        f = QFont()
        f.setPointSize(14)
        f.setBold(True)
        title.setFont(f)
        layout.addWidget(title)

        info = QLabel(
            f"Source: <a href='{html.escape(asset.url)}'>{html.escape(asset.url)}</a><br>"
            f"Size: {_fmt_size(asset.size_bytes)} — "
            f"Homepage: <a href='{html.escape(asset.homepage)}'>{html.escape(asset.homepage)}</a>"
        )
        info.setOpenExternalLinks(True)
        info.setTextFormat(Qt.RichText)
        info.setWordWrap(True)
        layout.addWidget(info)

        body = QTextBrowser()
        body.setOpenExternalLinks(True)
        body.setHtml(
            f"<p>{html.escape(asset.license_summary)}</p>"
            f"<p><b>Full terms:</b> "
            f"<a href='{html.escape(asset.license_url)}'>{html.escape(asset.license_url)}</a></p>"
            "<p>AmiCachy will fetch the archive directly from the author's "
            "server. The project does not host or redistribute these files.</p>"
        )
        layout.addWidget(body, 1)

        self._cb = QCheckBox("I have read and accept the terms above.")
        layout.addWidget(self._cb)

        bb = QDialogButtonBox(QDialogButtonBox.Cancel)
        self._continue = bb.addButton("Continue", QDialogButtonBox.AcceptRole)
        self._continue.setEnabled(False)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        layout.addWidget(bb)

        self._cb.toggled.connect(self._continue.setEnabled)


# ---------------------------------------------------------------------------
# Custom URL dialog
# ---------------------------------------------------------------------------


class URLAssetDialog(QDialog):
    """Manual install: user pastes a URL and chooses a base profile.

    No upstream license to display, so the user must explicitly accept
    full responsibility for the asset's legality (per project policy:
    'always checkbox' for manual sources).
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Add asset from URL")
        self.resize(560, 420)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(10)

        title = QLabel("Add asset from URL")
        f = QFont()
        f.setPointSize(14)
        f.setBold(True)
        title.setFont(f)
        layout.addWidget(title)

        layout.addWidget(QLabel(
            "Paste the direct URL of a .zip archive containing your bundle "
            "(typically an .hdf file inside)."
        ))

        form = QFormLayout()
        form.setSpacing(8)

        self._url = QLineEdit()
        self._url.setPlaceholderText("https://example.com/path/to/bundle.zip")
        form.addRow("URL:", self._url)

        self._name = QLineEdit()
        self._name.setPlaceholderText("(optional — defaults to the filename)")
        form.addRow("Name:", self._name)

        self._sha = QLineEdit()
        self._sha.setPlaceholderText("(optional — leave empty to compute on the fly)")
        form.addRow("Expected sha256:", self._sha)

        self._profile = QComboBox()
        for pid, label, _tpl in presets.BASE_PROFILES:
            self._profile.addItem(label, pid)
        form.addRow("Base profile:", self._profile)

        layout.addLayout(form)

        warning = QLabel(
            "<i>AmiCachy does not host, validate or vouch for arbitrary URLs. "
            "You confirm that you have the right to download and use this "
            "content under whatever terms apply to it.</i>"
        )
        warning.setWordWrap(True)
        warning.setStyleSheet("color: #c0c8e0; font-size: 12px;")
        layout.addWidget(warning)

        self._accept_cb = QCheckBox("I understand and accept full responsibility.")
        layout.addWidget(self._accept_cb)

        bb = QDialogButtonBox(QDialogButtonBox.Cancel)
        self._ok = bb.addButton("Install", QDialogButtonBox.AcceptRole)
        self._ok.setEnabled(False)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        layout.addWidget(bb)

        # Enable Install only when URL has content AND the accept box is ticked.
        self._url.textChanged.connect(self._refresh_ok)
        self._accept_cb.toggled.connect(self._refresh_ok)

    def _refresh_ok(self) -> None:
        self._ok.setEnabled(
            bool(self._url.text().strip()) and self._accept_cb.isChecked()
        )

    # --- Result accessors -----------------------------------------------------

    def url(self) -> str:
        return self._url.text().strip()

    def display_name(self) -> str:
        return self._name.text().strip()

    def expected_sha256(self) -> str:
        return self._sha.text().strip()

    def base_profile_id(self) -> str:
        return self._profile.currentData()


# ---------------------------------------------------------------------------
# Local file dialog
# ---------------------------------------------------------------------------


class FileAssetDialog(QDialog):
    """Manual install from a local file (zip or hdf raw).

    Discovers USB pendrives automounted by udisks2 under /run/media/$USER
    and surfaces them as one-click shortcuts. Falls back to a regular
    file picker for everything else.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Add asset from local file")
        self.resize(620, 520)

        self._selected_path: Path | None = None

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(10)

        title = QLabel("Add asset from local file")
        f = QFont()
        f.setPointSize(14)
        f.setBold(True)
        title.setFont(f)
        layout.addWidget(title)

        layout.addWidget(QLabel(
            "Pick a .zip bundle or a raw .hdf hardfile. Pendrives auto-mounted "
            "by the system appear below; otherwise use 'Browse…'."
        ))

        # USB shortcuts list (collapsible-feeling — hidden if empty).
        self._usb_label = QLabel("Detected removable media:")
        self._usb_label.setStyleSheet("font-weight: bold; margin-top: 6px;")
        layout.addWidget(self._usb_label)

        self._usb_list = QListWidget()
        self._usb_list.setMaximumHeight(120)
        self._usb_list.itemDoubleClicked.connect(self._on_usb_double_clicked)
        layout.addWidget(self._usb_list)

        actions = QHBoxLayout()
        self._btn_rescan = QPushButton("Rescan USB")
        self._btn_rescan.clicked.connect(self._scan_usb)
        actions.addWidget(self._btn_rescan)
        self._btn_browse = QPushButton("Browse…")
        self._btn_browse.clicked.connect(self._browse)
        actions.addWidget(self._btn_browse)
        actions.addStretch()
        layout.addLayout(actions)

        self._path_label = QLabel("(no file selected)")
        self._path_label.setStyleSheet(
            "padding: 6px; background-color: #1a2a4a; "
            "border: 1px solid #3b67a2; color: #cfd6ee;"
        )
        self._path_label.setWordWrap(True)
        layout.addWidget(self._path_label)

        # Asset info (name + base profile)
        form = QFormLayout()
        form.setSpacing(8)

        self._name = QLineEdit()
        self._name.setPlaceholderText("(optional — defaults to the filename)")
        form.addRow("Name:", self._name)

        self._profile = QComboBox()
        for pid, label, _tpl in presets.BASE_PROFILES:
            self._profile.addItem(label, pid)
        form.addRow("Base profile:", self._profile)

        layout.addLayout(form)

        warning = QLabel(
            "<i>AmiCachy does not validate or vouch for arbitrary files. "
            "You confirm that you have the right to use this content under "
            "whatever terms apply to it.</i>"
        )
        warning.setWordWrap(True)
        warning.setStyleSheet("color: #c0c8e0; font-size: 12px;")
        layout.addWidget(warning)

        self._accept_cb = QCheckBox("I understand and accept full responsibility.")
        layout.addWidget(self._accept_cb)

        bb = QDialogButtonBox(QDialogButtonBox.Cancel)
        self._ok = bb.addButton("Install", QDialogButtonBox.AcceptRole)
        self._ok.setEnabled(False)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        layout.addWidget(bb)

        self._accept_cb.toggled.connect(self._refresh_ok)

        # Initial USB scan (silent — empty list just hides the section).
        self._scan_usb()

    # --- USB discovery -------------------------------------------------------

    def _scan_usb(self) -> None:
        from . import installer
        mounts = installer.list_removable_mounts()

        self._usb_list.clear()
        if not mounts:
            self._usb_label.setVisible(False)
            self._usb_list.setVisible(False)
            self._btn_rescan.setText("Detect USB")
            return

        self._usb_label.setVisible(True)
        self._usb_list.setVisible(True)
        self._btn_rescan.setText("Rescan USB")
        for m in mounts:
            item = QListWidgetItem(f"{m.name}    ({m})")
            item.setData(Qt.UserRole, str(m))
            self._usb_list.addItem(item)

    def _on_usb_double_clicked(self, item: QListWidgetItem) -> None:
        """Open a file dialog rooted at the chosen USB mount."""
        root = item.data(Qt.UserRole)
        self._open_browse_at(root)

    def _browse(self) -> None:
        # Default to home if no USB picked yet.
        self._open_browse_at(str(Path.home()))

    def _open_browse_at(self, root: str) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Select asset file",
            root,
            "Asset files (*.zip *.hdf);;Zip archives (*.zip);;Hardfiles (*.hdf);;All files (*)",
        )
        if not path:
            return
        self._set_file(Path(path))

    def _set_file(self, path: Path) -> None:
        self._selected_path = path
        size = ""
        try:
            size = f"  ({_fmt_size(path.stat().st_size)})"
        except OSError:
            pass
        self._path_label.setText(f"{path}{size}")
        self._refresh_ok()

    # --- Validation ----------------------------------------------------------

    def _refresh_ok(self) -> None:
        self._ok.setEnabled(
            self._selected_path is not None and self._accept_cb.isChecked()
        )

    # --- Result accessors ----------------------------------------------------

    def file_path(self) -> str:
        return str(self._selected_path) if self._selected_path else ""

    def display_name(self) -> str:
        return self._name.text().strip()

    def base_profile_id(self) -> str:
        return self._profile.currentData()


# ---------------------------------------------------------------------------
# Background install worker
# ---------------------------------------------------------------------------


class InstallWorker(QThread):
    """Runs installer.install_asset() off the GUI thread.

    Emits progress(stage, current, total). Marshalling via Qt signals
    keeps QProgressBar updates safe.

    Two modes:
    - kind="catalog": runs install_asset(asset). Use this for entries
      that already exist in the catalog (with sha256, license, etc.).
    - kind="url": runs install_from_url(url, name, profile, sha256).
      Use this for manually-added URLs.
    """

    progress = Signal(str, int, int)
    finished_ok = Signal(str)
    failed = Signal(str)

    def __init__(self, kind: str, payload: dict):
        super().__init__()
        self.kind = kind
        self.payload = payload

    def run(self):
        def cb(stage, current, total):
            self.progress.emit(stage, current, total)
        try:
            if self.kind == "catalog":
                path = installer.install_asset(self.payload["asset"], progress_cb=cb)
            elif self.kind == "url":
                p = self.payload
                asset = installer.install_from_url(
                    url=p["url"],
                    name=p["name"],
                    base_profile_id=p["profile"],
                    expected_sha256=p.get("sha256", ""),
                    progress_cb=cb,
                )
                path = Path(state.installed_record(asset.id)["path"])
            elif self.kind == "file":
                p = self.payload
                asset = installer.install_from_file(
                    path=p["path"],
                    name=p["name"],
                    base_profile_id=p["profile"],
                    progress_cb=cb,
                )
                path = Path(state.installed_record(asset.id)["path"])
            else:
                raise installer.InstallError(f"unknown worker kind: {self.kind}")
            self.finished_ok.emit(str(path))
        except installer.InstallError as e:
            self.failed.emit(str(e))
        except Exception as e:  # network/IO errors not wrapped in InstallError
            self.failed.emit(f"{type(e).__name__}: {e}")


# ---------------------------------------------------------------------------
# Exit dialog (Reboot / Power off / Cancel)
# ---------------------------------------------------------------------------


class ExitDialog(QDialog):
    """Three-way exit dialog shown when the user presses 'Close'.

    The Asset Manager runs as a fullscreen Cage app — there is no desktop
    to fall back to. Instead of just closing (which would relaunch us via
    the autologin loop), we ask the user what they want to do next:

    - Reboot — go back to the systemd-boot menu and pick a different
      profile (Classic 68k, Dev Station…). The standard 'I'm done with
      the Asset Manager' action.
    - Power off — actually end the session.
    - Cancel — stay in the Asset Manager.
    """

    REBOOT = 1
    POWEROFF = 2
    CANCEL = 3

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Exit Asset Manager")
        self.choice = self.CANCEL

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(12)

        title = QLabel("What would you like to do?")
        f = QFont()
        f.setPointSize(13)
        f.setBold(True)
        title.setFont(f)
        layout.addWidget(title)

        layout.addWidget(QLabel(
            "The Asset Manager has no desktop to return to.\n"
            "Choose how to leave."
        ))

        btn_reboot = QPushButton("Reboot to boot menu")
        btn_reboot.setObjectName("primaryButton")
        btn_reboot.clicked.connect(lambda: self._pick(self.REBOOT))
        layout.addWidget(btn_reboot)

        btn_off = QPushButton("Power off")
        btn_off.clicked.connect(lambda: self._pick(self.POWEROFF))
        layout.addWidget(btn_off)

        btn_cancel = QPushButton("Cancel")
        btn_cancel.clicked.connect(self.reject)
        layout.addWidget(btn_cancel)

        self.setMinimumWidth(360)

    def _pick(self, value: int) -> None:
        self.choice = value
        self.accept()


def _system_action(action: str) -> None:
    """Trigger reboot or poweroff via systemd-logind (no sudo needed when
    the caller is in an active local seat — that's our case under cage)."""
    cmd = ["systemctl", action]
    try:
        subprocess.Popen(cmd, start_new_session=True)
    except OSError:
        # Fallback for unusual setups; will silently no-op if neither path works.
        try:
            subprocess.Popen(["loginctl", action], start_new_session=True)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------


class FetchAssetWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AmiCachy — Asset Library")
        self.resize(960, 600)

        self._catalog = cat_mod.load_catalog()
        self._worker: InstallWorker | None = None

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Header
        header = QWidget()
        header.setFixedHeight(48)
        header.setStyleSheet(f"background-color: {AMIGA_BLUE};")
        hlay = QHBoxLayout(header)
        hlay.setContentsMargins(16, 0, 16, 0)
        title = QLabel("AmiCachy — Asset Library")
        title.setObjectName("headerTitle")
        hlay.addWidget(title)
        hlay.addStretch()
        root.addWidget(header)

        # Body
        body_container = QWidget()
        bl = QVBoxLayout(body_container)
        bl.setContentsMargins(12, 12, 12, 8)
        bl.setSpacing(8)

        body = QSplitter(Qt.Horizontal)
        bl.addWidget(body, 1)

        self._list = QListWidget()
        self._list.setMinimumWidth(260)
        for a in self._catalog:
            tag = " ✓" if state.is_installed(a.id) else ""
            item = QListWidgetItem(f"{a.name}{tag}\n  {_fmt_size(a.size_bytes)}")
            item.setData(Qt.UserRole, a.id)
            self._list.addItem(item)
        self._list.currentRowChanged.connect(self._on_select)
        body.addWidget(self._list)

        self._detail = QTextBrowser()
        self._detail.setOpenExternalLinks(True)
        body.addWidget(self._detail)
        body.setSizes([300, 660])

        root.addWidget(body_container, 1)

        # Footer
        footer = QWidget()
        fl = QHBoxLayout(footer)
        fl.setContentsMargins(16, 8, 16, 12)
        fl.setSpacing(10)

        self._status = QLabel("")
        fl.addWidget(self._status, 0)

        self._bar = QProgressBar()
        self._bar.setVisible(False)
        self._bar.setMinimumWidth(280)
        fl.addWidget(self._bar, 1)

        # Add menu (URL / local file).
        self._btn_add = QPushButton("Add asset…")
        self._add_menu = QMenu(self)
        a_url = QAction("From URL…", self)
        a_url.triggered.connect(self._on_add_from_url)
        self._add_menu.addAction(a_url)
        a_file = QAction("From local file…", self)
        a_file.triggered.connect(self._on_add_from_file)
        self._add_menu.addAction(a_file)
        self._btn_add.setMenu(self._add_menu)
        fl.addWidget(self._btn_add)

        self._btn_install = QPushButton("Install")
        self._btn_install.setObjectName("primaryButton")
        self._btn_install.clicked.connect(self._on_install)
        fl.addWidget(self._btn_install)

        self._btn_remove = QPushButton("Remove")
        self._btn_remove.clicked.connect(self._on_remove)
        fl.addWidget(self._btn_remove)

        self._btn_close = QPushButton("Close")
        self._btn_close.clicked.connect(self._on_close_clicked)
        fl.addWidget(self._btn_close)

        root.addWidget(footer)

        if self._catalog:
            self._list.setCurrentRow(0)
        else:
            self._detail.setHtml("<p><i>No assets defined in the catalog.</i></p>")
            self._btn_install.setEnabled(False)
            self._btn_remove.setEnabled(False)

    # --- Selection -----------------------------------------------------------

    def _current_asset(self):
        item = self._list.currentItem()
        if item is None:
            return None
        return cat_mod.get_asset(self._catalog, item.data(Qt.UserRole))

    def _on_select(self, _row: int):
        a = self._current_asset()
        if a is None:
            self._detail.setHtml("")
            return
        record = state.installed_record(a.id)
        installed_html = (
            f"<p><b>Installed</b> at <code>{html.escape(record['path'])}</code></p>"
            if record else ""
        )
        version_html = f"<br><b>Version:</b> {html.escape(a.version)}" if a.version else ""
        self._detail.setHtml(f"""
            <h2>{html.escape(a.name)}</h2>
            {installed_html}
            <p>{html.escape(a.summary)}</p>
            <p>
              <b>Size:</b> {_fmt_size(a.size_bytes)}{version_html}<br>
              <b>Source:</b> <a href="{html.escape(a.url)}">{html.escape(a.url)}</a><br>
              <b>Homepage:</b> <a href="{html.escape(a.homepage)}">{html.escape(a.homepage)}</a><br>
              <b>License:</b> <a href="{html.escape(a.license_url)}">{html.escape(a.license_url)}</a>
            </p>
            <hr>
            <p><i>{html.escape(a.license_summary)}</i></p>
        """)
        self._btn_install.setEnabled(record is None and self._worker is None)
        self._btn_remove.setEnabled(record is not None and self._worker is None)

    # --- Actions -------------------------------------------------------------

    def _on_install(self):
        a = self._current_asset()
        if a is None:
            return
        if not state.is_accepted(a.id):
            dlg = LicenseDialog(a, self)
            if dlg.exec() != QDialog.Accepted:
                return
            state.mark_accepted(a.id)

        self._start_worker(InstallWorker("catalog", {"asset": a}))

    def _on_add_from_url(self):
        if self._worker is not None:
            return
        dlg = URLAssetDialog(self)
        if dlg.exec() != QDialog.Accepted:
            return
        self._start_worker(InstallWorker("url", {
            "url": dlg.url(),
            "name": dlg.display_name(),
            "profile": dlg.base_profile_id(),
            "sha256": dlg.expected_sha256(),
        }))

    def _on_add_from_file(self):
        if self._worker is not None:
            return
        dlg = FileAssetDialog(self)
        if dlg.exec() != QDialog.Accepted:
            return
        self._start_worker(InstallWorker("file", {
            "path": dlg.file_path(),
            "name": dlg.display_name(),
            "profile": dlg.base_profile_id(),
        }))

    def _start_worker(self, worker: "InstallWorker") -> None:
        """Common path to launch any kind of install. Wires up signals,
        toggles UI state, makes sure we don't run two at the same time."""
        self._bar.setVisible(True)
        self._bar.setRange(0, 100)
        self._bar.setValue(0)
        self._set_busy(True)
        self._status.setText("Starting…")

        self._worker = worker
        self._worker.progress.connect(self._on_progress)
        self._worker.finished_ok.connect(self._on_done)
        self._worker.failed.connect(self._on_fail)
        self._worker.start()

    def _on_remove(self):
        a = self._current_asset()
        if a is None or not state.is_installed(a.id):
            return
        ans = QMessageBox.question(
            self,
            "Remove asset",
            f"Remove '{a.name}' and delete its files?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if ans != QMessageBox.Yes:
            return
        installer.uninstall_asset(a.id)
        self._refresh_list()
        self._on_select(self._list.currentRow())

    # --- Worker callbacks ----------------------------------------------------

    def _on_progress(self, stage: str, current: int, total: int):
        self._status.setText(stage)
        if total <= 0:
            self._bar.setRange(0, 0)  # indeterminate
        else:
            # Avoid integer overflow on > 2 GB downloads when value > 2^31.
            if total > 100_000_000:
                self._bar.setRange(0, 100)
                self._bar.setValue(int(100 * current / total))
            else:
                self._bar.setRange(0, total)
                self._bar.setValue(current)

    def _on_done(self, path: str):
        self._set_busy(False)
        self._bar.setVisible(False)
        self._status.setText("")
        QMessageBox.information(
            self,
            "Installed",
            f"Installation finished.\n\nLocation:\n{path}\n\n"
            "The new entry is now available in Early Startup Control "
            "as a Configuration Profile."
        )
        self._worker = None
        self._refresh_list()
        self._on_select(self._list.currentRow())

    def _on_fail(self, msg: str):
        self._set_busy(False)
        self._bar.setVisible(False)
        self._status.setText("")
        QMessageBox.critical(self, "Install failed", msg)
        self._worker = None
        self._on_select(self._list.currentRow())

    # --- UI state ------------------------------------------------------------

    def _set_busy(self, busy: bool):
        self._btn_install.setEnabled(not busy)
        self._btn_remove.setEnabled(not busy)
        self._btn_close.setEnabled(not busy)
        self._btn_add.setEnabled(not busy)
        self._list.setEnabled(not busy)

    # --- Exit flow --------------------------------------------------------

    def _on_close_clicked(self) -> None:
        """Footer Close button. Always offers the reboot/poweroff dialog."""
        self._prompt_exit()

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt API
        """Window-manager close (X button, Alt+F4) also goes through the
        exit dialog. Outside cage (development on host), the user can
        cancel and keep the window open; under cage there is no [X]."""
        # If the user is mid-install, refuse and ask them to wait.
        if self._worker is not None:
            QMessageBox.warning(
                self,
                "Install in progress",
                "An installation is running. Wait for it to finish before exiting."
            )
            event.ignore()
            return

        if self._prompt_exit():
            event.accept()
        else:
            event.ignore()

    def _prompt_exit(self) -> bool:
        """Show the exit dialog. Returns True if the user picked an action
        that effectively ends the session (reboot/poweroff), False if they
        cancelled."""
        dlg = ExitDialog(self)
        if dlg.exec() != QDialog.Accepted:
            return False
        if dlg.choice == ExitDialog.REBOOT:
            _system_action("reboot")
            return True
        if dlg.choice == ExitDialog.POWEROFF:
            _system_action("poweroff")
            return True
        return False

    def _refresh_list(self):
        """Reload catalog (system + user) and rebuild the list rows.

        Reloading is necessary because adding an asset via URL persists
        a new entry in the user catalog that the original snapshot
        captured at __init__ time does not know about.
        """
        self._catalog = cat_mod.load_catalog()

        current_id = None
        if self._list.currentItem():
            current_id = self._list.currentItem().data(Qt.UserRole)

        self._list.blockSignals(True)
        self._list.clear()
        for a in self._catalog:
            tag = " ✓" if state.is_installed(a.id) else ""
            badge = " [user]" if a.source == "user" else ""
            label = f"{a.name}{badge}{tag}\n  {_fmt_size(a.size_bytes)}"
            item = QListWidgetItem(label)
            item.setData(Qt.UserRole, a.id)
            self._list.addItem(item)
            if a.id == current_id:
                self._list.setCurrentItem(item)
        self._list.blockSignals(False)
        if self._list.currentRow() < 0 and self._list.count():
            self._list.setCurrentRow(0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    app = QApplication.instance() or QApplication(sys.argv)
    if AMIGA_STYLESHEET:
        app.setStyleSheet(AMIGA_STYLESHEET)
    w = FetchAssetWindow()
    w.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
