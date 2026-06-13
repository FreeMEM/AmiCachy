/* SPDX-License-Identifier: CC0-1.0
 *
 * Placeholder slideshow for F3. The real Workbench slideshow (port of
 * tools/installer/slideshow.py) is F5.
 */
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0A2A"
            Text {
                anchors.centerIn: parent
                color: "#FF8800"
                font.pixelSize: 24
                horizontalAlignment: Text.AlignHCenter
                text: "AmiCachy\nPreparando tu estación Amiga…"
            }
        }
    }
}
