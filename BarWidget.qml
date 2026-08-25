import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "gotar.ai-usage"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function toggle() { if (panelItem) panelItem.toggle() }
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }
  function refresh() { if (panelItem) panelItem.refresh() }
  function localStart() { if (panelItem) panelItem.localStart() }
  function localStop() { if (panelItem) panelItem.localStop() }
  function localToggle() { if (panelItem) panelItem.localToggle() }

  function injectPanel() {
    var target = panelItem
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panelItem ? root.panelItem.barText() : "󰚩  …"
    fontSize: Style.font.bodySmall
    active: root.panelItem ? root.panelItem.alarming : false
    tooltipText: root.panelItem ? root.panelItem.tooltipText() : "AI usage"
    horizontalMargin: 8.5
    onPressed: function(code) {
      if (code === Qt.RightButton) {
        if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation ai-usagebar-tui")
        root.close()
      } else if (code === Qt.MiddleButton) {
        if (root.panelItem) root.panelItem.localToggle()
      } else root.toggle()
    }
    onWheelMoved: function(delta) {
      // wheel cycles refresh
      if (delta !== 0 && root.panelItem) root.panelItem.refresh()
    }
  }
}
