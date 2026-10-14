# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module Runtime
    class WaybarPresenterTest < Minitest::Test
      include CronbarTestHelpers

      # The chip is a cached-state renderer: its failing count must come
      # from run history (runs.json), not be empty because the caller
      # passed no runs. A failing latest manual run must turn the chip red
      # and add the class, so the bar never glows green over a dead job.
      def test_chip_counts_failing_runs_from_cached_history
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          path = write_config(config, File.join(home, "config.json"))
          write_snapshot(config, [cron_job])
          Cronbar::Runtime::State.append_run(config, run_record(jobId: "user", status: "failed", exitCode: 2))

          output = StringIO.new
          Cronbar::Runtime::Waybar.render(path, out: output)
          chip = JSON.parse(output.string)

          assert_includes chip.fetch("text"), "!1"
          assert_includes chip.fetch("class"), "has-failures"
        end
      end

      def run_record(overrides = {})
        {
          runId: "r1", jobId: "user", command: "echo hi", surface: "user",
          source: "crontab -l", startedAt: "2026-10-14T09:00:00Z",
          dryRun: false, status: "failed", exitCode: 2,
          stdout: "", stderr: "boom", finishedAt: "2026-10-14T09:00:01Z"
        }.merge(overrides)
      end
    end
  end
end