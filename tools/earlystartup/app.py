"""AmiCachy Early Startup Control — application entry point."""

import os
import sys

from PySide6.QtWidgets import QApplication

from .menu import EarlyStartupMenu
from .theme import AMIGA_STYLESHEET


def main():
    os.environ.setdefault("QT_QPA_PLATFORM", "wayland")
    os.environ.setdefault("XDG_SESSION_TYPE", "wayland")

    app = QApplication(sys.argv)
    app.setApplicationName("AmiCachy Early Startup")
    app.setStyleSheet(AMIGA_STYLESHEET)

    menu = EarlyStartupMenu()
    # Use show() instead of showFullScreen() — cage (kiosk compositor)
    # handles fullscreen automatically. showFullScreen() triggers a race
    # condition in wlroots 0.19: cage configures the XDG surface before
    # Qt has committed the initial state → assertion failure.
    menu.show()

    sys.exit(app.exec())
