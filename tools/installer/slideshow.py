"""Image slideshow widget for the installation progress page."""

from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import QLabel, QVBoxLayout, QWidget

SLIDESHOW_DIR = "/usr/share/amicachy/installer/slideshow"
SLIDE_INTERVAL_MS = 8000


class SlideshowWidget(QWidget):
    """Cycles through images with optional text captions."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._images: list[Path] = []
        self._index: int = 0

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        self._label = QLabel()
        self._label.setAlignment(Qt.AlignCenter)
        self._label.setStyleSheet("background: black;")
        layout.addWidget(self._label, stretch=1)

        self._caption = QLabel()
        self._caption.setAlignment(Qt.AlignCenter)
        self._caption.setStyleSheet(
            "color: white; font-size: 14px; padding: 8px; background: #0d1117;"
        )
        self._caption.setWordWrap(True)
        layout.addWidget(self._caption)

        self._timer = QTimer(self)
        self._timer.timeout.connect(self._next_slide)

        self._load_images()

    def _load_images(self) -> None:
        slide_dir = Path(SLIDESHOW_DIR)
        if slide_dir.is_dir():
            self._images = sorted(
                p for p in slide_dir.iterdir()
                if p.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp")
            )
        if not self._images:
            self._label.setText("Installing your Amiga workstation...")
            self._label.setStyleSheet(
                "color: white; font-size: 22px; background: #1a1a2e;"
            )
            self._caption.hide()

    def start(self) -> None:
        if self._images:
            self._show_slide(0)
            self._timer.start(SLIDE_INTERVAL_MS)

    def stop(self) -> None:
        self._timer.stop()

    def _next_slide(self) -> None:
        if not self._images:
            return
        self._index = (self._index + 1) % len(self._images)
        self._show_slide(self._index)

    def _show_slide(self, index: int) -> None:
        path = self._images[index]
        pixmap = QPixmap(str(path))
        if not pixmap.isNull():
            scaled = pixmap.scaled(
                self._label.size(),
                Qt.KeepAspectRatio,
                Qt.SmoothTransformation,
            )
            self._label.setPixmap(scaled)

        caption_path = path.with_suffix(".txt")
        if caption_path.exists():
            self._caption.setText(caption_path.read_text().strip())
            self._caption.show()
        else:
            self._caption.setText("")
            self._caption.hide()
