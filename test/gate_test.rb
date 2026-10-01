# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module CLI
    class GateTest < Minitest::Test
      include CronbarTestHelpers

      def test_gate_accepts_the_correct_passphrase
        with_temp_home do
          with_gate_pass("hunter2") do
            assert Cronbar::CLI.gate("hunter2")
          end
        end
      end

      def test_gate_rejects_wrong_passphrases
        with_temp_home do
          with_gate_pass("hunter2") do
            refute Cronbar::CLI.gate("hunter3")
            refute Cronbar::CLI.gate("")
          end
        end
      end

      def test_gate_fails_closed_when_the_pass_file_is_missing
        with_temp_home do |home|
          old = Cronbar::Core::Config.gate_path
          Cronbar::Core::Config.gate_path = File.join(home, "missing.pass")
          begin
            refute Cronbar::CLI.gate("anything")
          ensure
            Cronbar::Core::Config.gate_path = old
          end
        end
      end

      def test_run_command_executes_end_to_end_with_pass
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          config_path = write_config(config, File.join(home, "config.json"))
          write_snapshot(config, [cron_job(command: "echo gated")])

          with_gate_pass("s3cret") do
            out, _err = capture_io do
              code = Cronbar::CLI.run(["run", "user", "--pass", "s3cret", "--config", config_path, "--format", "json"])

              assert_equal 0, code
            end

            payload = JSON.parse(out, symbolize_names: true)
            assert_equal "success", payload[:status]
            assert_includes payload[:stdout], "gated"
          end
        end
      end

      def test_run_command_rejects_a_wrong_pass
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          config_path = write_config(config, File.join(home, "config.json"))
          write_snapshot(config, [cron_job(command: "echo never")])

          with_gate_pass("s3cret") do
            _out, err = capture_io do
              code = Cronbar::CLI.run(["run", "user", "--pass", "wrong", "--config", config_path])

              assert_equal 2, code
            end

            assert_match(/wrong passphrase/, err)
          end

          assert_empty Cronbar::Runtime::State.read_runs(config)[:runs]
        end
      end

      def test_run_command_refuses_without_a_pass
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          config_path = write_config(config, File.join(home, "config.json"))
          write_snapshot(config, [cron_job])

          with_gate_pass("s3cret") do
            old_pass = ENV.delete("CRONBAR_RUN_PASS")
            begin
              _out, err = capture_io do
                code = Cronbar::CLI.run(["run", "user", "--config", config_path])

                assert_equal 1, code
              end
              assert_match(/refusing to execute/, err)
            ensure
              ENV["CRONBAR_RUN_PASS"] = old_pass if old_pass
            end
          end
        end
      end

      def test_run_command_reports_unknown_job
        with_temp_home do |home|
          config = temp_config(File.join(home, "state"))
          config_path = write_config(config, File.join(home, "config.json"))
          write_snapshot(config, [cron_job])

          with_gate_pass("s3cret") do
            _out, err = capture_io do
              code = Cronbar::CLI.run(["run", "ghost", "--pass", "s3cret", "--config", config_path])

              assert_equal 1, code
            end

            assert_match(/unknown job id/, err)
          end
        end
      end
    end
  end
end
