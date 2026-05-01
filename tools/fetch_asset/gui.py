"""Qt frontend — Asset Library window.

Reuses the Amiga Workbench theme defined in earlystartup/theme.py so that
the asset manager visually matches the Early Startup Control screen.
"""

from __future__ import annotations

import html
import sys

from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QDialog,
    QDialogButtonBox,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSplitter,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from . import catalog as cat_mod
from . import installer, state

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
# Background install worker
# ---------------------------------------------------------------------------


class InstallWorker(QThread):
    """Runs installer.install_asset() off the GUI thread.

    Emits progress(stage, current, total). Marshalling via Qt signals
    keeps QProgressBar updates safe.
    """

    progress = Signal(str, int, int)
    finished_ok = Signal(str)
    failed = Signal(str)

    def __init__(self, asset):
        super().__init__()
        self.asset = asset

    def run(self):
        def cb(stage, current, total):
            self.progress.emit(stage, current, total)
        try:
            path = installer.install_asset(self.asset, progress_cb=cb)
            self.finished_ok.emit(str(path))
        except installer.InstallError as e:
            self.failed.emit(str(e))
        except Exception as e:  # network/IO errors not wrapped in InstallError
            self.failed.emit(f"{type(e).__name__}: {e}")


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

        self._btn_install = QPushButton("Install")
        self._btn_install.setObjectName("primaryButton")
        self._btn_install.clicked.connect(self._on_install)
        fl.addWidget(self._btn_install)

        self._btn_remove = QPushButton("Remove")
        self._btn_remove.clicked.connect(self._on_remove)
        fl.addWidget(self._btn_remove)

        self._btn_close = QPushButton("Close")
        self._btn_close.clicked.connect(self.close)
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

        self._bar.setVisible(True)
        self._bar.setRange(0, 100)
        self._bar.setValue(0)
        self._set_busy(True)
        self._status.setText("Starting…")

        self._worker = InstallWorker(a)
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
        self._list.setEnabled(not busy)

    def _refresh_list(self):
        # Re-render all rows so the "✓ installed" tag stays accurate.
        current_id = None
        if self._list.currentItem():
            current_id = self._list.currentItem().data(Qt.UserRole)
        self._list.blockSignals(True)
        self._list.clear()
        for a in self._catalog:
            tag = " ✓" if state.is_installed(a.id) else ""
            item = QListWidgetItem(f"{a.name}{tag}\n  {_fmt_size(a.size_bytes)}")
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
