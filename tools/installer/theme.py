"""Visual theme constants and global stylesheet."""

STATUS_COLORS = {
    "green": "#27ae60",
    "yellow": "#f39c12",
    "red": "#c0392b",
}

BG_PRIMARY = "#1a1a2e"
BG_CARD = "#16213e"
BORDER = "#0f3460"
ACCENT = "#e94560"
TEXT_PRIMARY = "#e0e0e0"
TEXT_DIM = "#888"

GLOBAL_STYLESHEET = """
QWidget {
    background-color: #1a1a2e;
    color: #e0e0e0;
    font-family: "Noto Sans", "DejaVu Sans", sans-serif;
    font-size: 14px;
}

QPushButton {
    background-color: #16213e;
    border: 1px solid #0f3460;
    border-radius: 6px;
    padding: 10px 24px;
    color: #e0e0e0;
    font-size: 15px;
}

QPushButton:hover {
    background-color: #0f3460;
}

QPushButton:disabled {
    background-color: #0d1b2a;
    color: #555;
}

QPushButton#primaryButton {
    background-color: #e94560;
    border: none;
    color: white;
    font-weight: bold;
}

QPushButton#primaryButton:hover {
    background-color: #c73e54;
}

QPushButton#primaryButton:disabled {
    background-color: #5a2030;
    color: #888;
}

QProgressBar {
    border: 1px solid #0f3460;
    border-radius: 4px;
    text-align: center;
    background-color: #16213e;
    min-height: 22px;
}

QProgressBar::chunk {
    background-color: #e94560;
    border-radius: 3px;
}

QScrollArea {
    border: none;
}

QPlainTextEdit {
    background-color: #0d1117;
    color: #c9d1d9;
    font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace;
    font-size: 12px;
    border: 1px solid #0f3460;
    border-radius: 4px;
}

QLabel#headerTitle {
    font-size: 20px;
    font-weight: bold;
    color: white;
}

QLabel#pageTitle {
    font-size: 18px;
    font-weight: bold;
    color: white;
    padding-bottom: 8px;
}

QLabel#subtitle {
    font-size: 14px;
    color: #aaa;
}

QLabel#warning {
    color: #e94560;
    font-weight: bold;
}

QCheckBox {
    spacing: 8px;
    font-size: 14px;
}

QCheckBox::indicator {
    width: 18px;
    height: 18px;
}

QComboBox {
    background-color: #16213e;
    border: 1px solid #0f3460;
    border-radius: 4px;
    padding: 6px 12px;
    color: #e0e0e0;
}

QComboBox::drop-down {
    border: none;
}

QComboBox QAbstractItemView {
    background-color: #16213e;
    color: #e0e0e0;
    selection-background-color: #0f3460;
}
"""
