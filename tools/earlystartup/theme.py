"""Amiga Workbench 3.x visual theme for Early Startup Control."""

# Classic Amiga Workbench 3.x palette
AMIGA_GREY = "#959595"       # Background grey (color 0)
AMIGA_BLACK = "#000000"      # Text / dark shadow (color 1)
AMIGA_WHITE = "#ffffff"      # Highlight / bevel light (color 2)
AMIGA_BLUE = "#3b67a2"       # Screen title bar (color 3)
AMIGA_LIGHT = "#b0b0b0"      # Lighter grey for button face
AMIGA_DARK = "#555555"       # Dark bevel shadow

AMIGA_STYLESHEET = """
QWidget {
    background-color: #959595;
    color: #000000;
    font-family: "Noto Sans", "DejaVu Sans", sans-serif;
    font-size: 14px;
}

QPushButton {
    background-color: #b0b0b0;
    border-top: 2px solid #ffffff;
    border-left: 2px solid #ffffff;
    border-bottom: 2px solid #000000;
    border-right: 2px solid #000000;
    padding: 6px 20px;
    color: #000000;
    font-size: 14px;
}

QPushButton:hover {
    background-color: #c0c0c0;
}

QPushButton:pressed {
    background-color: #888888;
    border-top: 2px solid #000000;
    border-left: 2px solid #000000;
    border-bottom: 2px solid #ffffff;
    border-right: 2px solid #ffffff;
}

QPushButton:disabled {
    background-color: #959595;
    color: #666666;
    border-top: 2px solid #b0b0b0;
    border-left: 2px solid #b0b0b0;
    border-bottom: 2px solid #555555;
    border-right: 2px solid #555555;
}

QPushButton#primaryButton {
    background-color: #b0b0b0;
    border-top: 2px solid #ffffff;
    border-left: 2px solid #ffffff;
    border-bottom: 2px solid #000000;
    border-right: 2px solid #000000;
    color: #000000;
    font-weight: bold;
}

QPushButton#primaryButton:hover {
    background-color: #c0c0c0;
}

QPushButton#primaryButton:pressed {
    background-color: #888888;
    border-top: 2px solid #000000;
    border-left: 2px solid #000000;
    border-bottom: 2px solid #ffffff;
    border-right: 2px solid #ffffff;
}

QComboBox {
    background-color: #b0b0b0;
    border-top: 2px solid #ffffff;
    border-left: 2px solid #ffffff;
    border-bottom: 2px solid #000000;
    border-right: 2px solid #000000;
    padding: 4px 8px;
    color: #000000;
}

QComboBox::drop-down {
    subcontrol-origin: padding;
    subcontrol-position: center right;
    width: 24px;
    border-left: 2px solid #000000;
    background-color: #b0b0b0;
}

QComboBox::down-arrow {
    image: none;
    border-left: 5px solid transparent;
    border-right: 5px solid transparent;
    border-top: 6px solid #000000;
    width: 0px;
    height: 0px;
}

QComboBox QAbstractItemView {
    background-color: #b0b0b0;
    color: #000000;
    selection-background-color: #3b67a2;
    selection-color: #ffffff;
    border: 1px solid #000000;
}

QRadioButton {
    spacing: 6px;
    color: #000000;
}

QRadioButton::indicator {
    width: 14px;
    height: 14px;
    border-radius: 7px;
    border: 2px solid #000000;
    background-color: #b0b0b0;
}

QRadioButton::indicator:checked {
    background-color: #3b67a2;
    border: 2px solid #000000;
}

QRadioButton:disabled {
    color: #666666;
}

QRadioButton::indicator:disabled {
    background-color: #959595;
    border: 2px solid #666666;
}

QLabel#headerTitle {
    font-size: 18px;
    font-weight: bold;
    color: #ffffff;
}

QLabel#sectionTitle {
    font-size: 13px;
    font-weight: bold;
    color: #000000;
}

QFrame#amigaSection {
    background-color: #959595;
    border-top: 2px solid #000000;
    border-left: 2px solid #000000;
    border-bottom: 2px solid #ffffff;
    border-right: 2px solid #ffffff;
    padding: 10px;
}
"""
