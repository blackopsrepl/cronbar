# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module Runtime
    class StateTest < Minitest::Test
      include CronbarTestHelpers

      def test_build_snapshot_projects_summary_and_surfaces
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          jobs = [
            cron_job(command: "echo a"),
            cron_job(command: "sudo mount -a", privilege: "sudo"),
            cron_job(command: "echo off", commented: true),
            anacron_job
          ]

          snapshot = write_snapshot(config, jobs)

          assert_equal "ok", snapshot[:status]
          assert_equal 3, snapshot[:summary][:jobCount]
          assert_equal 1, snapshot[:summary][:commentedJobCount]
          assert_equal 2, snapshot[:summary][:cronJobCount]
          assert_equal 1, snapshot[:summary][:anacronJobCount]
          assert_equal 1, snapshot[:summary][:sudoJobCount]

          user_surface = snapshot[:surfaces].find { |s| s[:id] == "user" }
          assert_equal 2, user_surface[:jobCount]
          assert_equal 1, user_surface[:commentedCount]
          refute user_surface[:locked]

          assert snapshot[:view][:chip][:text].start_with?("CRB ")
        end
      end

      def test_surface_overview_marks_locked_surfaces
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          errors = [{ code: "surface-locked", context: "sys", message: "locked: run sudo as root" }]

          snapshot = write_snapshot(config, [cron_job], errors: errors)

          sys = snapshot[:surfaces].find { |s| s[:id] == "sys" }
          assert sys[:locked]
          assert_equal "locked: run sudo as root", sys[:note]
        end
      end

      def test_write_snapshot_updates_state_event
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          write_snapshot(config, [cron_job])

          event = Cronbar::Runtime::State.read_json(Cronbar::Runtime::State.state_event_path(config))
          assert event[:updatedAt]
        end
      end

      def test_stale_detection
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          fresh = { generatedAt: Time.now.iso8601 }
          old = { generatedAt: (Time.now - 7200).iso8601 }

          refute Cronbar::Runtime::State.stale?(fresh, config)
          assert Cronbar::Runtime::State.stale?(old, config)
          assert Cronbar::Runtime::State.stale?(nil, config)
        end
      end

      def test_error_snapshot_carries_message
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          snapshot = Cronbar::Runtime::State.build_error_snapshot("scan exploded")

          assert_equal "error", snapshot[:status]
          assert_equal "scan exploded", snapshot[:errors].first[:message]
          assert_equal 0, snapshot[:summary][:jobCount]
        end
      end

      def test_run_history_appends_and_caps_at_200
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          210.times do |i|
            Cronbar::Runtime::State.append_run(config, { runId: i })
          end

          runs = Cronbar::Runtime::State.read_runs(config)
          assert_equal 200, runs[:runs].length
          assert_equal 10, runs[:runs].first[:runId]
        end
      end

      def test_ui_state_round_trips_normalized
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          Cronbar::Runtime::State.write_ui_state(config, { open: true, requestedAt: "2026-10-01T10:00:00Z" })

          state = Cronbar::Runtime::State.read_ui_state(config)
          assert state[:open]
          assert_equal "2026-10-01T10:00:00Z", state[:requestedAt]
        end
      end
    end
  end
end
