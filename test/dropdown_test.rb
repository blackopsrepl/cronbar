# frozen_string_literal: true

require_relative "test_helper"

# Bounded bar drop-down contract for the QuickShell panel.
#
# The panel used to be a full-screen PanelWindow: a screen-sized surface with a
# centerIn card and a screen-wide scrim pair behind it. A covering modal is the
# wrong shape for a bar companion. Switchyard 8cda212 landed the counted-height,
# frame-shadow, live-dot drop-down but kept the full-screen surface; this
# contract takes CronBar the rest of the way — the PanelWindow itself shrinks
# to exactly the card's rect (a top-anchored bar strip), so the desktop under
# and beside it stays interactive.
#
# qmllint cannot resolve the Quickshell ShellRoot type, so the panel's
# load-bearing shape is asserted here by source contract, complementing the
# headless render proof.
class DropDownTest < Minitest::Test
  PANEL = File.expand_path("../frontend/quickshell/shell.qml", __dir__)

  def panel_source
    @panel_source ||= File.read(PANEL)
  end

  def panel_window_block
    panel_source[/PanelWindow \{(.*?)\n    \}\n/m, 1].to_s
  end

  def test_panelwindow_surface_is_bounded_to_the_bar_edge_strip
    block = panel_window_block
    refute_empty block, "PanelWindow block not found"

    anchors = block[/anchors \{(.*?)\}/m, 1].to_s
    assert_includes anchors, "top: true"
    assert_includes anchors, "left: true"
    assert_includes anchors, "right: true"
    # The bottom anchor is what made the surface cover the whole screen.
    refute_includes anchors, "bottom: true"

    # The surface sizes itself from the card geometry (plus the margin above
    # the bar), never from the full screen.
    assert_match(/implicitWidth:\s*panelWidth\(\)/, block)
    assert_match(/implicitHeight:\s*panelHeight\(\)/, block)
    refute_match(/screen\?\s*screen\.width/, block)
    refute_match(/screen\?\s*screen\.height/, block)

    # The whole-surface input mask was the screen-shaped catcher; with a
    # bounded surface, bounds ARE the catcher and the mask must be gone.
    refute_match(/mask:\s*Region/m, block)
  end

  def test_geometry_is_counted_from_laid_out_parts_and_capped_to_the_viewport
    source = panel_source
    assert_match(/property int panelTopMargin: 52/, source)
    assert_match(/property int panelMaxWidth: 1180/, source)
    assert_match(/property int panelMinHeight: 480/, source)

    height = source[/function panelHeight\(\) \{(.*?)\n    \}\n/m, 1].to_s
    refute_empty height, "panelHeight() not found"
    # Counted, not measured: visible list rows at their pitch plus declared
    # chrome and the alerts band — never an implicit-size sum.
    assert_match(/Math\.min\(.*\.length,\s*12\)/, height)
    assert_match(/var alertsHeight/, height)
    assert_match(/var chromeCounted = /, height)
    # The cap is always the true viewport minus the bar margin and a breathing
    # gap, so the strip never reaches the screen's bottom edge; the floor keeps
    # the detail surface usable only until the viewport cap takes over.
    assert_match(/\(screen \? screen\.height : 900\) - root\.panelTopMargin - 12/, height)

    width = source[/function panelWidth\(\) \{(.*?)\n    \}\n/m, 1].to_s
    refute_empty width, "panelWidth() not found"
    # Content-fit with a floor, never the full screen.
    assert_match(/Math\.min\(root\.panelMaxWidth/, width)
    assert_match(/\(screen \? screen\.width : 1440\)/, width)
  end

  def test_modal_frame_fills_the_bounded_window_instead_of_floating_centered
    # The frame's own anchor block must fill the bounded window; no centering
    # clamp survives inside it (delegate-level centering inside panes is fine).
    frame_head = panel_source[/id: modalFrame(.*?)color:/m, 1].to_s
    refute_empty frame_head, "modalFrame not found"
    refute_includes frame_head, "anchors.centerIn: parent"
    assert_match(/id: modalFrame\s+anchors\.fill: parent/m, panel_source)
    # The card fills the window minus only the shadow drop band.
    assert_includes frame_head, "anchors.bottomMargin: root.shadowDrop"
  end

  def test_no_scrim_or_backdrop_layer_survives_in_the_bounded_surface
    # The two dark scrims behind the card rendered a dimmed overlay; the
    # bounded surface shows the card and its shadow, nothing else.
    refute_includes panel_source, 'color: Qt.rgba(0, 0, 0, 0.22)'
    refute_includes panel_source, 'color: Qt.rgba(0, 0, 0, 0.34)'
    # No screen-wide dim layer, no card-plus-N scrim rect: nothing centered
    # under the card, and the only dark rectangle is the shadow itself.
    panel_item = panel_source[/Item \{\s*id: panelItem(.*?)\n            \}\n/m, 1].to_s
    assert panel_item, "panelItem not found"
    refute_match(/anchors\.centerIn: parent/, panel_item)
  end

  def test_dismissal_is_esc_and_the_strip_catcher_not_a_screen_wide_catcher
    source = panel_source
    # Esc keeps both paths: the window Shortcut and the card-level key handler.
    assert_match(/sequence: "Esc"/, source)
    assert_includes source, "Keys.onEscapePressed: root.closeModal()"

    # The strip catcher: a click inside the bounded window but outside the
    # card radius dismisses. Bounded behind the card's radius it is invisible,
    # so it must be transparent.
    assert_match(/MouseArea\s*\{\s*id:\s*stripCatcher\s+anchors\.fill:\s*parent\s+z:\s*-2\s+onClicked:\s*root\.closeModal/m, source)
    catcher = source[/id:\s*stripCatcher.*?\n            \}/m].to_s
    assert_includes catcher, "onClicked: root.closeModal()"
    refute_includes panel_source, 'mask: Region'

    # Dead space inside the card stays inert: the card catcher (z below the
    # content) must remain so a click on card padding does not close.
    card = panel_source.split("id: modalFrame", 2).last
    assert_match(/MouseArea\s*\{\s*id:\s*cardCatcher\s+anchors\.fill: parent\s+z:\s*-1\s*\}/m, card)
  end

  def test_frame_carries_the_shadow_drop_separation
    source = panel_source
    assert_match(/id: frameShadow/m, source)
    assert_match(/color: Qt\.rgba\(0, 0, 0, 0\.35\)/, source)
    shadow = source[/id: frameShadow.*?\n            \}/m].to_s
    refute_empty shadow
    # The shadow hangs from the card's top edge, exactly the card's box.
    assert_match(/width: modalFrame\.width/, shadow)
    assert_match(/height: modalFrame\.height/, shadow)
  end

  def test_header_carries_the_live_dot
    source = panel_source
    assert_match(/id: liveDot/m, source)
    # Green when idle, amber while a command runs, red on an error snapshot.
    assert_match(/id: liveDot.*?actionRunner\.running.*?root\.theme\.warn/m, source)
    assert_match(/root\.statusChip\.tone === "bad" \? root\.theme\.bad/, source)
  end

  def test_breakpoints_bind_to_the_bounded_panel_geometry
    source = panel_source
    assert_match(/property bool narrowLayout: panel\.width < 720/, source)
    # shortViewport reads the viewport (screen minus the bar strip), not the
    # panel's own height, which would tie a binding loop into panelHeight().
    assert_match(/property bool narrowLayout: panel\.width < 720/, source)
    assert_match(/property bool shortViewport: \(\(root\.panelScreen\(\)/, source)
    refute_includes source, "modal.width < 720"
    refute_includes source, "modal.height < 560"
    refute_match(/shortViewport:\s*panel\.height/, source)
  end

  def test_ui_docs_describe_the_bounded_drop_down_and_its_dismissal_trade
    readme = File.read(File.expand_path("../README.md", __dir__))
    architecture = File.read(File.expand_path("../docs/architecture.md", __dir__))
    cli = File.read(File.expand_path("../docs/cli.md", __dir__))

    [readme, architecture].each do |body|
      assert_includes body, "drops below the bar edge"
      assert_includes body, "bounded PanelWindow surface"
    end
    # The honest dismissal trade, stated where the panel's interactions are
    # described: a bounded surface cannot see clicks on the desktop outside it.
    assert_match(/Esc, the Close button, or a click\s+on the exposed strip/i, cli)
    refute_includes architecture, "only actual backdrop clicks close the modal"
  end

  # Flow (a positioner) lays its children out by width/height; Rectangle has
  # no implicit size, so the surface/metric tiles rendered 0x0 with their text
  # spilling overdrawn in a single garbled line. The tiles must declare
  # implicit sizes measured from their own content.
  def test_flow_tiles_declare_implicit_sizes
    surface = panel_source[/component SurfaceCard: Rectangle \{(.*?)\n    \}\n/m, 1].to_s
    refute_empty surface, "SurfaceCard component not found"
    assert_match(/implicitWidth:/, surface, "SurfaceCard carries a content-measured implicitWidth")
    assert_match(/implicitHeight: 64/, surface, "SurfaceCard declares its 64px pitch")
    metric = panel_source[/component MetricTile: Rectangle \{(.*?)\n    \}\n/m, 1].to_s
    refute_empty metric, "MetricTile component not found"
    assert_match(/implicitWidth:/, metric, "MetricTile carries a content-measured implicitWidth")
    assert_match(/implicitHeight: 62/, metric, "MetricTile declares its 62px pitch")
    # The retired fill-only shape must not come back: Layout.fillWidth inside
    # a positioner is ignored and leaves the tile unsized.
    refute_match(/Layout\.fillWidth: true\s*\n\s*Layout\.preferredHeight:/, surface)
    refute_match(/Layout\.fillWidth: true\s*\n\s*Layout\.preferredHeight:/, metric)
  end

  def test_cronbar_keeps_its_read_only_surface
    # CronBar is a monitor: no mutation controls may appear on the panel.
    refute_match(/label: "(Start|Stop|Restart|Toggle|Kill|Edit)"/, panel_source)
  end
end
