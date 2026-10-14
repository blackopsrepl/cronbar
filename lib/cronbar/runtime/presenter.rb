# frozen_string_literal: true

module Cronbar
  module Runtime
    module Presenter
      module_function

      def build_summary(jobs, runs: [])
        commented = jobs.count { |job| job[:commented] }
        {
          jobCount: jobs.length - commented,
          commentedJobCount: commented,
          activeJobCount: jobs.count { |job| !job[:commented] && job[:surface] != "anacron" },
          cronJobCount: jobs.count { |job| !job[:commented] && job[:kind] == "cron" },
          anacronJobCount: jobs.count { |job| !job[:commented] && job[:kind] == "anacron" },
          sudoJobCount: jobs.count { |job| job[:privilege] == "sudo" },
          manualRunCount: runs.count { |record| !record[:dryRun] },
          failingJobCount: failing_job_ids(runs).length,
          soonest: soonest_job(jobs),
          errorCount: 0
        }
      end

      # The latest non-dry run per job decides: a later success clears an
      # earlier failure, a timeout is incomplete rather than clean.
      def failing_job_ids(runs)
        outcomes = {}
        runs.each do |record|
          next if record[:dryRun]

          outcomes[record[:jobId]] = record
        end
        outcomes.values
                .select { |record| record[:status] == "failed" || record[:status] == "timeout" }
                .map { |record| record[:jobId] }
                .compact.uniq
      end

      def surface_overview(jobs, errors, runs: [])
        grouped = jobs.group_by { |job| job[:surface] }
        %w[user sys cron.d anacron].map do |surface|
          surface_jobs = Array(grouped[surface])
          surface_errors = errors.select { |e| e[:context] == surface }
          surface_ids = surface_jobs.map { |job| job[:id] }
          {
            id: surface,
            label: Core::Format.surface_label(surface),
            jobCount: surface_jobs.count { |job| !job[:commented] },
            commentedCount: surface_jobs.count { |job| job[:commented] },
            failingCount: failing_job_ids(runs).count { |id| surface_ids.include?(id) },
            locked: surface_errors.any? { |e| e[:code] == "surface-locked" },
            note: surface_errors.first&.fetch(:message)
          }
        end
      end

      def build_snapshot_view(snapshot, stale:, runs: [])
        summary = (snapshot[:summary] || {}).merge(errorCount: Array(snapshot[:errors]).length)
        summary = summary.merge(manualRunCount: runs.count { |record| !record[:dryRun] },
                                failingJobCount: failing_job_ids(runs).length)
        status = stale ? "stale" : snapshot[:status].to_s
        jobs = Array(snapshot[:jobs])
        surfaces = Array(snapshot[:surfaces])

        {
          chip: {
            text: Core::Format.chip_text(summary, status),
            tooltipLines: Core::Format.tooltip_lines(snapshot, stale: stale),
            classes: chip_classes(summary, status, jobs)
          },
          statusChip: status_chip(summary, status, Array(snapshot[:errors]), runs),
          alerts: partial_failure_alerts(jobs, Array(snapshot[:errors]), runs),
          summary: summary,
          surfaces: surfaces,
          jobs: jobs,
          errors: Array(snapshot[:errors]),
          generatedAt: snapshot[:generatedAt]
        }
      end

      # The headline must not hide partial failure behind a word: issues
      # (unreadable/locked surfaces) and failing manual runs are counted in
      # the text and pushed to the matching non-good tone.
      def status_chip(summary, status, errors, runs)
        return { text: "error", tone: "bad" } if status == "error"
        return { text: "stale", tone: "muted" } if status == "stale"

        issues = errors.length
        failing = summary[:failingJobCount].to_i
        text = status.empty? ? "unknown" : status
        if issues.positive? || failing.positive?
          parts = [text]
          parts << "#{issues} issue#{issues == 1 ? "" : "s"}" if issues.positive?
          parts << "#{failing} failing" if failing.positive?
          text = parts.join(" · ")
        end
        { text: text, tone: issues.positive? || failing.positive? ? "warn" : "good" }
      end

      # Alerts carry the partial failure into the panel: one line per
      # unreadable surface error and one per job whose latest manual run
      # failed or timed out. A clean snapshot produces no alerts.
      def partial_failure_alerts(jobs, errors, runs)
        alerts = errors.map { |error| { tone: "bad", text: alert_text(error[:context], error[:message]) } }

        failing_ids = failing_job_ids(runs)
        failing_ids.each do |id|
          job = jobs.find { |candidate| candidate[:id] == id }
          record = runs.reverse.find { |r| !r[:dryRun] && r[:jobId] == id }
          alerts << { tone: "warn",
                      text: alert_text(job ? job[:surface] : nil,
                                       "#{job ? job[:command].to_s : id} — #{run_status_text(record)}") }
        end
        alerts
      end

      def alert_text(context, message)
        context && !context.to_s.empty? ? "#{context}: #{message}" : message.to_s
      end

      def run_status_text(record)
        case record[:status].to_s
        when "failed" then with_exit_code(record, "failed")
        when "timeout" then "timeout (incomplete)"
        when "dry-run" then "dry-run preview"
        when "success" then "success"
        else record[:status].to_s.empty? ? "unknown" : record[:status].to_s
        end
      end

      def with_exit_code(record, word)
        code = record[:exitCode]
        code.nil? || code == "" ? word : "#{word} (exit #{code})"
      end

      def chip_classes(summary, status, jobs)
        classes = ["cronbar", status]
        classes << "no-jobs" if summary[:jobCount].to_i.zero?
        classes << "has-commented" if summary[:commentedJobCount].to_i.positive?
        classes << "has-sudo" if summary[:sudoJobCount].to_i.positive?
        classes << "has-errors" if summary[:errorCount].to_i.positive?
        classes << "has-failures" if summary[:failingJobCount].to_i.positive?
        classes << "soon" if soon_minutes(jobs)
        classes.compact.uniq
      end

      def soon_minutes(jobs, window: 60)
        times = jobs.filter_map { |job| job[:commented] ? nil : job[:nextAt] }
                    .filter_map { |value| State.parse_time(value) }
        return nil if times.empty?

        delta = times.min - Time.now
        delta.positive? && delta <= window * 60 ? delta : nil
      end

      def soonest_job(jobs)
        jobs.filter_map { |job| job[:commented] ? nil : job }
            .filter_map { |job| (t = State.parse_time(job[:nextAt])) ? [t, job] : nil }
            .min_by { |t, _job| t }
            &.last
      end
    end
  end
end
