# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module Runtime
    class PresenterTest < Minitest::Test
      include CronbarTestHelpers

      def presenter
        Cronbar::Runtime::Presenter
      end

      def run_record(overrides = {})
        {
          runId: "r1", jobId: "user", command: "echo hi", surface: "user",
          source: "crontab -l", startedAt: "2026-10-14T09:00:00Z",
          dryRun: false, status: "success", exitCode: 0,
          stdout: "hi", stderr: "", finishedAt: "2026-10-14T09:00:01Z"
        }.merge(overrides)
      end

      # ----------------------------------------------------------------
      # Status-text vocabulary: the panel renders presenter text, it does
      # not assemble its own outcome strings from raw fields.
      # ----------------------------------------------------------------

      def test_run_status_text_names_the_outcome_scope
        assert_equal "success", presenter.run_status_text(run_record)
        assert_equal "failed (exit 2)", presenter.run_status_text(run_record(status: "failed", exitCode: 2))
        assert_equal "failed (exit 130)", presenter.run_status_text(run_record(status: "failed", exitCode: 130))
        assert_equal "timeout (incomplete)", presenter.run_status_text(run_record(status: "timeout", exitCode: nil))
        assert_equal "dry-run preview", presenter.run_status_text(run_record(status: "dry-run", dryRun: true))
        assert_equal "unknown", presenter.run_status_text(run_record(status: ""))
      end

      def test_build_summary_counts_manual_runs_and_recently_failing_jobs
        jobs = [cron_job(id: "user"), cron_job(command: "echo b", id: "user@2")]
        runs = [
          run_record(jobId: "user", status: "failed", exitCode: 1),
          run_record(jobId: "user@2", status: "failed", exitCode: 2),
          run_record(jobId: "user", status: "success", exitCode: 0),
          run_record(jobId: "user", status: "dry-run", dryRun: true)
        ]

        summary = presenter.build_summary(jobs, runs: runs)

        assert_equal 3, summary[:manualRunCount]
        # The latest non-dry run per job decides; "user" recovered with a
        # later success, so only "user@2" counts as failing.
        assert_equal 1, summary[:failingJobCount]
      end

      def test_build_summary_without_runs_keeps_zeroed_run_facts
        summary = presenter.build_summary([cron_job])

        assert_equal 0, summary[:manualRunCount]
        assert_equal 0, summary[:failingJobCount]
      end

      # ----------------------------------------------------------------
      # Truthful headline: a snapshot with issues or failing runs must
      # not report a blanket green "ok".
      # ----------------------------------------------------------------

      def test_snapshot_view_reports_a_truthful_status_chip
        snapshot = {
          status: "ok",
          summary: presenter.build_summary([cron_job]),
          jobs: [cron_job],
          surfaces: [],
          generatedAt: "2026-10-14T09:00:00Z",
          errors: [{ code: "surface-locked", context: "sys", message: "locked" }]
        }
        runs = [run_record(jobId: "user", status: "failed", exitCode: 2, stderr: "boom")]

        view = presenter.build_snapshot_view(snapshot, stale: false, runs: runs)

        assert_equal({ text: "ok · 1 issue · 1 failing", tone: "warn" }, view[:statusChip])

        alerts = view[:alerts]
        assert alerts.any? { |a| a[:tone] == "bad" && a[:text].include?("sys: locked") }
        assert alerts.any? { |a| a[:tone] == "warn" && a[:text].include?("user") && a[:text].include?("failed (exit 2)") }
      end

      def test_snapshot_view_reports_a_clean_ok_chip_only_when_clean
        snapshot = {
          status: "ok",
          summary: presenter.build_summary([cron_job]),
          jobs: [cron_job],
          surfaces: [],
          generatedAt: "2026-10-14T09:00:00Z",
          errors: []
        }

        clean = presenter.build_snapshot_view(snapshot, stale: false, runs: [])
        assert_equal({ text: "ok", tone: "good" }, clean[:statusChip])

        stale = presenter.build_snapshot_view(snapshot, stale: true, runs: [])
        assert_equal({ text: "stale", tone: "muted" }, stale[:statusChip])
      end

      def test_error_snapshot_reports_a_bad_error_chip
        snapshot = {
          status: "error",
          summary: presenter.build_summary([]),
          jobs: [],
          surfaces: [],
          generatedAt: "2026-10-14T09:00:00Z",
          errors: [{ code: "cronbar-failed", context: nil, message: "scan exploded" }]
        }

        view = presenter.build_snapshot_view(snapshot, stale: false, runs: [])

        assert_equal({ text: "error", tone: "bad" }, view[:statusChip])
      end

      def test_chip_text_and_classes_surface_partial_failures
        jobs = [cron_job]
        runs = [run_record(jobId: "user", status: "failed", exitCode: 3)]
        summary = presenter.build_summary(jobs, runs: runs)

        classes = presenter.chip_classes(summary, "ok", jobs)
        assert_includes classes, "has-failures"
        assert_includes Cronbar::Core::Format.chip_text(summary, "ok"), "!1"
      end

      def test_surface_overview_counts_failing_jobs_per_surface
        surfaces = presenter.surface_overview(
          [cron_job], [], runs: [run_record(jobId: "user", status: "failed", exitCode: 2)]
        )
        assert_equal 1, surfaces.first[:failingCount]

        clean = presenter.surface_overview([cron_job], [], runs: [run_record(jobId: "user")])
        assert_equal 0, clean.first[:failingCount]
      end
    end
  end
end