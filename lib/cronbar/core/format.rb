# frozen_string_literal: true

module Cronbar
  module Core
    module Format
      module_function

      def chip_text(summary, status)
        jobs = summary[:jobCount].to_i
        active = summary[:activeJobCount].to_i

        return "CRB err" if status == "error"
        return "CRB idle" if jobs.zero?

        pieces = ["CRB #{jobs}j"]
        pieces << "#{active}*" if active.positive?
        anacron = summary[:anacronJobCount].to_i
        pieces << "#{anacron}an" if anacron.positive?
        pieces.join(" ")
      end

      def tooltip_lines(snapshot, stale: false, max_jobs: 50)
        summary = snapshot[:summary] || {}
        lines = []
        lines << "cronbar#{stale ? ' (stale)' : ''}"
        lines << "Jobs: #{summary[:jobCount].to_i} | Active: #{summary[:activeJobCount].to_i} | " \
                 "Commented: #{summary[:commentedJobCount].to_i} | Anacron: #{summary[:anacronJobCount].to_i}"

        grouped = Array(snapshot[:jobs]).group_by { |job| job[:surface] }
        grouped.each do |surface, jobs|
          lines << ""
          lines << "#{surface_label(surface)} (#{jobs.length})"
          jobs.first(max_jobs.to_i).each do |job|
            lines << "  #{job_line(job)}"
          end
          hidden = jobs.length - max_jobs.to_i
          lines << "  … #{hidden} more" if hidden.positive?
        end

        Array(snapshot[:errors]).first(4).each do |error|
          lines << "Error: #{error[:context] ? "#{error[:context]}: " : ''}#{error[:message]}"
        end

        lines
      end

      def job_line(job)
        schedule = job[:schedule].to_s.strip
        schedule = "?" if schedule.empty?
        state = job[:commented] ? "off" : "on"
        flags = []
        flags << job[:name] if job[:name]
        flags << "sudo" if job[:privilege] == "sudo"
        flags << "last #{job[:lastRun]}" if job[:lastRun]
        [job[:command], "[#{schedule}] #{state}", flags.compact.join(" · ")].reject(&:empty?).join("  ")
      end

      def surface_label(surface)
        case surface.to_s
        when "user" then "user crontab"
        when "sys" then "system crontab"
        when "cron.d" then "/etc/cron.d"
        when "anacron" then "anacron"
        else surface.to_s
        end
      end
    end
  end
end
