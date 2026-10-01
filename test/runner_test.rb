# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module Runtime
    class RunnerTest < Minitest::Test
      include CronbarTestHelpers

      def test_run_executes_the_job_command_and_records_success
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = write_snapshot(config, [cron_job(command: "echo cronbar-proof")])

          outcome = Runner.run_job(config, snapshot, "user")

          assert outcome[:ok]
          assert_equal "success", outcome[:record][:status]
          assert_equal 0, outcome[:record][:exitCode]
          assert_includes outcome[:record][:stdout], "cronbar-proof"
          refute outcome[:dryRun]
          assert_equal false, outcome[:record][:dryRun]

          runs = State.read_runs(config)
          assert_equal 1, runs[:runs].length
          assert_equal "user", runs[:runs].first[:jobId]
        end
      end

      def test_run_records_failures_with_exit_code_and_stderr
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = write_snapshot(config, [cron_job(command: "echo boom >&2; exit 3")])

          outcome = Runner.run_job(config, snapshot, "user")

          refute outcome[:ok]
          assert_equal "failed", outcome[:record][:status]
          assert_equal 3, outcome[:record][:exitCode]
          assert_includes outcome[:record][:stderr], "boom"
        end
      end

      def test_dry_run_reports_without_executing
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = write_snapshot(config, [cron_job(command: "touch #{home}/should-not-exist")])

          outcome = Runner.run_job(config, snapshot, "user", dry_run: true)

          assert outcome[:dryRun]
          assert_equal "dry-run", outcome[:record][:status]
          refute File.file?(File.join(home, "should-not-exist"))
          assert_empty State.read_runs(config)[:runs]
        end
      end

      def test_unknown_job_id_is_rejected
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = write_snapshot(config, [cron_job])

          outcome = Runner.run_job(config, snapshot, "nope")

          refute outcome[:ok]
          assert_match(/unknown job id/, outcome[:error])
        end
      end

      def test_commented_jobs_run_like_any_other
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = write_snapshot(config, [cron_job(command: "echo ghost", commented: true)])
          id = snapshot[:jobs].first[:id]

          outcome = Runner.run_job(config, snapshot, id)

          assert outcome[:ok]
          assert_includes outcome[:record][:stdout], "ghost"
        end
      end

      def test_output_is_truncated
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = write_snapshot(config, [cron_job(command: "yes | head -c 20000")])

          outcome = Runner.run_job(config, snapshot, "user")

          assert_operator outcome[:record][:stdout].length, :<=, 4100
          assert_includes outcome[:record][:stdout], "truncated"
        end
      end
    end
  end
end
