# frozen_string_literal: true

require "securerandom"
require "time"

module Cronbar
  module Runtime
    # Runs jobs manually. The command is the job's own line from its crontab,
    # executed through the configured shell exactly as cron would. Commented
    # jobs can be run the same way; the panel pass makes that a deliberate,
    # confirmed action.
    module Runner
      TIMEOUT_SECONDS = 3600

      module_function

      def run_job(config, snapshot, id, dry_run: false)
        job = find_job(snapshot, id)
        return unknown_job(id) unless job

        shell = config.dig(:runtime, :runnerShell).to_s
        record = {
          runId: SecureRandom.uuid,
          jobId: id,
          command: job[:command],
          surface: job[:surface],
          source: job[:source],
          startedAt: Time.now.utc.iso8601,
          dryRun: !!dry_run
        }

        if dry_run
          record[:status] = "dry-run"
          record[:finishedAt] = Time.now.utc.iso8601
          return { ok: true, dryRun: true, job: job, record: record }
        end

        result = State.with_lock(config, State::RUN_LOCK_FILE) do
          Core::Process.run_command(shell, ["-c", job[:command]], timeout: TIMEOUT_SECONDS)
        end

        record[:status] = result.timed_out ? "timeout" : (result.success? ? "success" : "failed")
        record[:exitCode] = result.exit_code
        record[:stderr] = truncate(result.stderr.to_s)
        record[:stdout] = truncate(result.stdout.to_s)
        record[:finishedAt] = Time.now.utc.iso8601
        State.append_run(config, record)

        { ok: record[:status] == "success", dryRun: false, job: job, record: record }
      end

      def find_job(snapshot, id)
        return nil unless snapshot.is_a?(Hash)

        Array(snapshot[:jobs]).find { |job| job[:id] == id }
      end

      def unknown_job(id)
        { ok: false, error: "unknown job id: #{id}" }
      end

      def truncate(text, limit: 4000)
        return text if text.length <= limit

        "#{text[0, limit]}… (truncated)"
      end
    end
  end
end
