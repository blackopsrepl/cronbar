# frozen_string_literal: true

require_relative "test_helper"

class PanelTest < Minitest::Test
  include CronbarTestHelpers

  def panel
    File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
  end

  def test_run_result_binding_matches_the_real_cli_payload
    with_temp_home do |home|
      config = temp_config(File.join(home, "state"))
      path = write_config(config, File.join(home, "config.json"))
      write_snapshot(config, [cron_job(command: "printf panel-proof")])
      with_gate_pass("test-only") do
        out, err = capture_io do
          assert_equal 0, Cronbar::CLI.run(["run", "user", "--pass", "test-only", "--format", "json", "--config", path])
        end
        assert_empty err
        record = JSON.parse(out)
        assert_equal "success", record.fetch("status")
        assert_equal 0, record.fetch("exitCode")
        assert_equal false, record.fetch("dryRun")
        refute record.key?("record")
        assert_includes panel, "payload.status"
        assert_includes panel, "payload.exitCode"
        refute_includes panel, "payload.record"
      end
    end
  end

  def test_history_binds_the_top_level_array
    assert_includes panel, "var runs = runsAdapter.runs"
    refute_includes panel, "runsAdapter.runs.runs"
    assert_includes panel, "property var runs: []"
  end

  def test_commands_are_queued_and_confirmation_does_not_move_controls
    assert_includes panel, "root.commandQueue.push(args)"
    assert_includes panel, "root.commandQueue.shift()"
    assert_includes panel, "if (!root.confirmArmed)"
    assert_includes panel, "Layout.preferredHeight: 24"
    assert_includes panel, "root.runPass = \"\""
  end

  def test_card_catches_unused_space_before_the_backdrop
    card = panel.split("id: modalFrame", 2).last
    assert_match(/MouseArea\s*\{\s*id:\s*cardCatcher\s+anchors\.fill: parent\s+z: -1\s*\}/, card)
    refute_includes panel, "logProbe"
    assert_includes panel, "property string runPass: \"\""
    assert_includes panel, "actionStdout.text.trim()"
    assert_includes panel, "actionStderr.text.trim()"
    refute_includes panel, "this.text"
  end

  # ------------------------------------------------------------------
  # Truthful status: the headline chip renders the presenter's
  # statusChip (text + tone), never a bare blanket-green snapshot word.
  # ------------------------------------------------------------------

  def test_status_chip_renders_presenter_text_and_tone_not_a_blanket_ok
    assert_includes panel, "viewData.statusChip"
    refute_includes panel, "text: snapshotAdapter.status || \"loading\"", "the old blanket status word chip must not return"
    assert_match(/function chipTone\(tone\)/, panel)
    assert_match(/chipTone\(.*tone/, panel)
    %w[good warn bad muted].each do |tone|
      assert_match(/tone === "#{tone}"\)\s*return/, panel)
    end
  end

  def test_alerts_strip_surfaces_partial_failures_without_elision
    strip = panel[/Repeater\s*\{\s*model: root\.alerts.*?\n                    \}/m]
    refute_nil strip, "the alerts strip renders each alert with its own Repeater item"
    assert_includes strip, "wrapMode: Text.Wrap", "alert lines wrap instead of collapsing behind an ellipsis"
    refute_includes strip, "elide", "alerts must not be elided away"
    assert_match(/modelData\.tone/, strip)
  end

  def test_metrics_name_their_scope
    assert_includes panel, '" failing"', "the failing tile must read as a scope, not a bare number"
    assert_includes panel, 'label: "jobs, this machine"'
    assert_includes panel, '" active"', "the active count names its scope"
    assert_includes panel, 'label: "commented, manual-only"'
  end


  def test_waybar_chip_css_rules_the_failure_class
    css = File.read(File.expand_path("../examples/waybar.css", __dir__))
    assert_includes css, "#custom-cronbar.has-failures"
  end

  def test_surface_cards_show_failing_count_when_present
    assert_includes panel, 'surface.failingCount'
  end

  # ------------------------------------------------------------------
  # Responsive layout (the Switchyard pattern): below 720px width the
  # panes stop sharing a row; below 560px height the chrome tightens.
  # ------------------------------------------------------------------

  def test_narrow_viewports_switch_between_full_width_list_and_detail
    assert_includes panel, "property bool narrowLayout: panel.width < 720"
    assert_includes panel, "((root.panelScreen() ? root.panelScreen().height : 900)"
    assert_includes panel, 'property string narrowPanelView: "jobs"'
    assert_match(/id: dashboardAreas.*?visible: !root\.narrowLayout/m, panel)
    assert_match(/visible: root\.narrowLayout.*?StackLayout/m, panel)
    assert_includes panel, 'root.narrowPanelView = "jobs"'
    assert_includes panel, 'root.narrowPanelView = "detail"'
    assert_includes panel, "anchors.margins: root.shortViewport ? 10 : 16"
    assert_includes panel, "spacing: root.shortViewport ? 8 : 12"
    assert_includes panel, "anchors.margins: root.shortViewport || compact ? 8 : 12", "detail chrome tightens on short viewports"
    assert_includes panel, "spacing: root.shortViewport || compact ? 6 : 10"
    # the bounded surface follows a narrow screen instead of keeping a 720px floor:
    assert_includes panel, "var availableWidth = Math.max(332, (screen ? screen.width : 1440) - 64)"
  end

  # The narrow stack is a sibling after wide content — one page at a time,
  # with detail reusing the same DetailPane the wide layout shows.
  def test_narrow_detail_reuses_the_shared_detail_pane
    assert_includes panel, "component DetailPane: Rectangle"
    assert_match(/sourceComponent: DetailPane \{/, panel)
    assert_includes panel, "compact: true"
  end

  def test_job_list_overflow_cue_is_visible_not_a_hidden_ellipsis
    assert_includes panel, '" · scroll" : ""'
    assert_match(/ScrollBar\.vertical: ScrollBar \{ policy: ScrollBar\.AsNeeded \}/, panel)
  end

  # ------------------------------------------------------------------
  # Family visual contract (the *-bar family, modelled on TokenMaxx's
  # square-cornered mac-bar look): no rounded corners anywhere. A
  # non-zero radius exists only for circles-that-are-dots (the 7px
  # live/status dot) or thin status stripes; frames, cards, buttons,
  # badges and the shadow are square.
  # ------------------------------------------------------------------

  def family_radius_declarations
    panel.scan(/^\s*radius:\s*(\d+(?:\.\d+)?)\s*$/).map(&:first)
  end

  def test_family_style_squares_every_corner_except_dot_circles
    offenders = family_radius_declarations.reject { |radius| %w[0 3.5].include?(radius) }
    assert_empty offenders,
                 "family square corners: every frame/card/button/shadow radius is 0, got #{offenders}"

    # Every surviving 3.5 must be a circle-that-is-a-dot: a 7x7 square
    # with the radius at half its width, within its immediate context.
    dots = 0
    panel.each_line.with_index(1) do |line, number|
      next unless (match = line.match(/^\s*radius:\s*3\.5\s*$/))

      context = panel.lines[(number - 4)...(number + 3)].join
      assert_match(/width:\s*7/, context, "shell.qml:#{number}: a radius 3.5 is only the 7px live/status dot")
      assert_match(/height:\s*7/, context, "shell.qml:#{number}: a radius 3.5 is only the 7px live/status dot")
      dots += 1
    end
    assert_operator dots, :>=, 1, "the live/status dot circles must survive the squaring"

    # The retired frame and inner-border rounding must not come back.
    %w[4 6 7 8 10 12].each do |retired|
      refute_includes family_radius_declarations, retired,
                      "radius #{retired} is off the family square-corner spec"
    end
  end

  def test_status_chip_and_cards_stay_square
    # The status chip rectangle and the header live-dot surroundings are
    # the family's square chrome: no radius may reappear beside them.
    chip = panel[/id: statusChipText.*?\n                    \}\n/m, 0].to_s
    frame = panel[/id: modalFrame(.*?)Keys\.onEscapePressed/m, 1].to_s
    refute_match(/radius:\s*[1-9]/, chip)
    refute_match(/radius:\s*[1-9]/, frame)
  end

  # ------------------------------------------------------------------
  # Diagnostics on the surface: last-run outcome, exit code and stderr
  # head render in the detail pane, never behind an ellipsis.
  # ------------------------------------------------------------------

  def test_detail_surfaces_last_run_diagnostics
    assert_includes panel, "function lastRunFacts()"
    assert_includes panel, "root.lastRunFacts()"
    assert_match(/lastRunFacts\(\)[^}]*Repeater/m, panel)
    assert_includes panel, "function runStatusText(record)"
    assert_includes panel, '"timeout (incomplete)"'
    assert_includes panel, '" (exit " + record.exitCode + ")"'
    assert_includes panel, '"stderr: " + latest.stderr.split'
    # the failure diagnostics must not collapse behind an ellipsis: the
    # Repeater renders one Text per fact and each wraps.
    pane = panel[/component DetailPane: Rectangle.*?\n    \}\n/m]
    assert pane, "the shared DetailPane component exists"
    assert_includes pane, "visible: root.lastRunFacts().length > 0", "the detail renders the run facts fact line"
    facts_block = pane[/visible: root\.lastRunFacts\(\)\.length > 0.*?\n            \}/m]
    refute_nil facts_block
    assert_includes facts_block, "Repeater {"
    assert_includes facts_block, "wrapMode: Text.Wrap", "facts wrap instead of eliding"
    refute_includes facts_block, "elide"
    assert_match(/DetailPane \{/, panel, "the wide pane instantiates the shared detail")
    assert_match(/sourceComponent: DetailPane \{/, panel, "the narrow pane instantiates the shared detail")
    refute_includes panel, "text: root.lastRunFacts().join(", "facts render line by line, not one elided string"
  end
end
