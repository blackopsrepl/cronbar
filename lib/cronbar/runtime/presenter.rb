# frozen_string_literal: true

module Cronbar
  module Runtime
    module Presenter
      module_function

      def build_summary(jobs)
        commented = jobs.count { |job| job[:commented] }
        {
          jobCount: jobs.length - commented,
          commentedJobCount: commented,
          activeJobCount: jobs.count { |job| !job[:commented] && job[:surface] != "anacron" },
          cronJobCount: jobs.count { |job| !job[:commented] && job[:kind] == "cron" },
          anacronJobCount: jobs.count { |job| !job[:commented] && job[:kind] == "anacron" },
          sudoJobCount: jobs.count { |job| job[:privilege] == "sudo" },
          soonest: soonest_job(jobs),
          errorCount: 0
        }
      end

      def surface_overview(jobs, errors)
        grouped = jobs.group_by { |job| job[:surface] }
        %w[user sys cron.d anacron].map do |surface|
          surface_jobs = Array(grouped[surface])
          surface_errors = errors.select { |e| e[:context] == surface }
          {
            id: surface,
            label: Core::Format.surface_label(surface),
            jobCount: surface_jobs.count { |job| !job[:commented] },
            commentedCount: surface_jobs.count { |job| job[:commented] },
            locked: surface_errors.any? { |e| e[:code] == "surface-locked" },
            note: surface_errors.first&.fetch(:message)
          }
        end
      end

      def build_snapshot_view(snapshot, stale:)
        summary = (snapshot[:summary] || {}).merge(errorCount: Array(snapshot[:errors]).length)
        status = stale ? "stale" : snapshot[:status].to_s
        jobs = Array(snapshot[:jobs])
        surfaces = Array(snapshot[:surfaces])

        {
          chip: {
            text: Core::Format.chip_text(summary, status),
            tooltipLines: Core::Format.tooltip_lines(snapshot, stale: stale),
            classes: chip_classes(summary, status, jobs)
          },
          summary: summary,
          surfaces: surfaces,
          jobs: jobs,
          errors: Array(snapshot[:errors]),
          generatedAt: snapshot[:generatedAt]
        }
      end

      def chip_classes(summary, status, jobs)
        classes = ["cronbar", status]
        classes << "no-jobs" if summary[:jobCount].to_i.zero?
        classes << "has-commented" if summary[:commentedJobCount].to_i.positive?
        classes << "has-sudo" if summary[:sudoJobCount].to_i.positive?
        classes << "has-errors" if summary[:errorCount].to_i.positive?
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
