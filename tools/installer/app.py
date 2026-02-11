"""AmiCachy Installer — application entry point."""

import os
import sys

from PySide6.QtWidgets import QApplication

from .pages import InstallerWizard
from .theme import GLOBAL_STYLESHEET


def main():
    # Enforce Wayland rendering
    os.environ.setdefault("QT_QPA_PLATFORM", "wayland")
    os.environ.setdefault("XDG_SESSION_TYPE", "wayland")

    app = QApplication(sys.argv)
    app.setApplicationName("AmiCachy Setup")
    app.setStyleSheet(GLOBAL_STYLESHEET)

    wizard = InstallerWizard()
    wizard.showFullScreen()

    sys.exit(app.exec())
