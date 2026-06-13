/* SPDX-License-Identifier: CC0-1.0
 *
 * Workbench 3.2.3-styled slideshow placeholder (F3). Real Workbench slideshow
 * (port of tools/installer/slideshow.py) is F5.
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
            color: "#A8A8A8"   // Workbench gray panel
            Column {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "#CC0000"   // AmigaOS red
                    font.pixelSize: 30
                    font.bold: true
                    text: "AmiCachy"
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "#000000"
                    font.pixelSize: 18
                    horizontalAlignment: Text.AlignHCenter
                    text: "Preparando tu estación Amiga…"
                }
            }
        }
    }
}
