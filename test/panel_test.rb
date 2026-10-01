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
    card = panel.split("id: card", 2).last
    assert_match(/MouseArea\s*\{\s*anchors.fill: parent\s*z: -1\s*\}/, card)
    refute_includes panel, "logProbe"
    assert_includes panel, "property string runPass: \"\""
    assert_includes panel, "actionStdout.text.trim()"
    assert_includes panel, "actionStderr.text.trim()"
    refute_includes panel, "this.text"
  end
end
