# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Cronbar
  module Core
    # Reads every cron surface into one job list: the user crontab, the system
    # crontab, /etc/cron.d, and anacron. Commented-out cron lines that still
    # look like real entries are collected as commented jobs so they can be run
    # manually. Root-owned surfaces are read through sudo when available and
    # reported as locked otherwise; they are never silently dropped.
    module Collectors
      SPECIAL_SCHEDULES = %w[@reboot @yearly @annually @monthly @weekly @daily @midnight @hourly].freeze
      CRON_D_NAME = /\A[A-Za-z0-9_-]+\z/.freeze
      ANACRON_PERIOD = /\A(\d+|@(?:daily|weekly|monthly|yearly))\z/.freeze

      module_function

      # Surface sources. Overridable in tests; production reads the real files.
      DEFAULT_SURFACE_PATHS = {
        "user" => nil,
        "sys" => "/etc/crontab",
        "cron.d" => "/etc/cron.d",
        "anacron" => "/etc/anacrontab",
        "anacron-spool" => "/var/spool/anacron"
      }.freeze

      def surface_paths
        @surface_paths || DEFAULT_SURFACE_PATHS
      end

      def surface_paths=(value)
        @surface_paths = value
      end

      def scan(config)
        jobs = []
        errors = []
        surfaces = config.dig(:surfaces) || {}

        jobs.concat(collect_user_crontab(config, errors)) if surfaces[:user]
        jobs.concat(collect_system_crontab(config, errors)) if surfaces[:system]
        jobs.concat(collect_cron_d(config, errors)) if surfaces[:cronD]
        jobs.concat(collect_anacron(config, errors)) if surfaces[:anacron]
        unless surfaces[:commented]
          jobs.reject! { |job| job[:commented] }
        end

        { jobs: assign_ids(jobs), errors: errors }
      end

      # ------------------------------------------------------------ collectors

      def collect_user_crontab(config, errors)
        if (path = surface_paths["user"])
          content = File.read(path)
          return parse_crontab(content, surface: "user", source: path, system: false)
        end

        result = Core::Process.run_command("crontab", ["-l"], timeout: 5)
        return [] if result.status&.exitstatus == 1 # no crontab installed
        unless result.success?
          errors << error("user", "crontab -l failed: #{result.stderr.to_s.strip}")
          return []
        end

        parse_crontab(result.stdout, surface: "user", source: "crontab -l", system: false)
      end

      def collect_system_crontab(config, errors)
        content, privilege = read_surface(surface_paths["sys"], config, errors, "sys")
        return [] if content.nil?

        parse_crontab(content, surface: "sys", source: surface_paths["sys"], system: true, privilege: privilege)
      end

      def collect_cron_d(config, errors)
        dir = surface_paths["cron.d"]
        unless File.directory?(dir)
          errors << error("cron.d", "#{dir} does not exist")
          return []
        end

        names = Dir.children(dir).grep(CRON_D_NAME).sort
        jobs = []
        names.each do |name|
          path = File.join(dir, name)
          content, privilege = read_surface(path, config, errors, "cron.d")
          next if content.nil?

          jobs.concat(parse_crontab(content, surface: "cron.d", source: path, system: true,
                                            privilege: privilege, name: name))
        end
        jobs
      end

      def collect_anacron(config, errors)
        content, privilege = read_surface(surface_paths["anacron"], config, errors, "anacron")
        return [] if content.nil?

        spool = read_anacron_spool(config, errors, privilege)
        parse_anacrontab(content, source: surface_paths["anacron"], privilege: privilege, spool: spool)
      end

      # ------------------------------------------------------------ surface IO

      # Returns [content, privilege] where privilege is "sudo" when the sudo
      # fallback was used, or [nil, nil] when the surface stays locked.
      def read_surface(path, config, errors, context)
        File.read(path)
      rescue Errno::EACCES, Errno::EPERM
        sudo = config.dig(:runtime, :sudoCommand).to_s
        result = Core::Process.run_command(sudo, ["cat", path], timeout: 10)
        if result.success?
          [result.stdout, "sudo"]
        else
          errors << locked_error(context, path)
          [nil, nil]
        end
      rescue Errno::ENOENT
        errors << error(context, "#{path} not found")
        [nil, nil]
      rescue StandardError => e
        errors << error(context, "#{path}: #{e.message}")
        [nil, nil]
      end

      def read_anacron_spool(config, errors, privilege)
        spool = {}
        dir = surface_paths["anacron-spool"]
        return spool unless File.directory?(dir)

        sudo = config.dig(:runtime, :sudoCommand).to_s
        Dir.children(dir).sort.each do |name|
          path = File.join(dir, name)
          raw =
            begin
              File.read(path)
            rescue Errno::EACCES, Errno::EPERM
              next unless privilege == "sudo"

              result = Core::Process.run_command(sudo, ["cat", path], timeout: 5)
              result.success? ? result.stdout : nil
            rescue StandardError
              nil
            end
          next if raw.nil?

          date = raw.strip[/\A(\d{8})\z/, 1]
          spool[name] = Time.parse("#{date[0, 4]}-#{date[4, 2]}-#{date[6, 2]} 00:00:00") if date
        end
        spool
      rescue StandardError => e
        errors << error("anacron", "spool unreadable: #{e.message}")
        spool
      end

      # ------------------------------------------------------------ parsers

      def parse_crontab(content, surface:, source:, system:, privilege: nil, name: nil)
        now = Time.now
        jobs = []
        content.each_line.with_index(1) do |line, line_no|
          stripped = line.strip
          commented = stripped.start_with?("#")
          entry = commented ? parse_commented_entry(stripped, system: system) : parse_active_entry(stripped, system: system)
          next if entry.nil?

          entry[:commented] = commented
          entry[:surface] = surface
          entry[:source] = source
          entry[:line] = line_no
          entry[:readPrivilege] = privilege if privilege
          entry[:name] = name if name
          decorate(entry, now)
          jobs << entry
        end
        jobs
      end

      def parse_anacrontab(content, source:, privilege: nil, spool: {})
        jobs = []
        content.each_line.with_index(1) do |line, line_no|
          stripped = line.strip
          commented = stripped.start_with?("#")
          entry = parse_anacron_entry(commented ? stripped.sub(/\A#+\s*/, "") : stripped)
          next if entry.nil?

          entry[:surface] = "anacron"
          entry[:source] = source
          entry[:line] = line_no
          entry[:readPrivilege] = privilege if privilege
          entry[:commented] = commented
          decorate_anacron(entry, spool)
          jobs << entry
        end
        jobs
      end

      def parse_active_entry(stripped, system:)
        return nil if stripped.empty? || stripped.start_with?("#")
        return nil if env_assignment?(stripped)

        tokens = stripped.split(/\s+/)
        if tokens[0].start_with?("@") && SPECIAL_SCHEDULES.include?(tokens[0])
          return nil if tokens.length < 2

          return job(command: tokens[1..].join(" "), schedule: tokens[0], period: tokens[0], user: nil)
        end

        return nil unless vixie_entry?(tokens)

        fields = tokens[0..4]
        rest = tokens[5..]
        if system
          user = rest[0]
          command = rest[1..].join(" ")
          return nil if command.to_s.empty?

          job(command: command, schedule: fields.join(" "), period: nil, user: user)
        else
          job(command: rest.join(" "), schedule: fields.join(" "), period: nil, user: nil)
        end
      end

      # A commented line counts as a commented job only when it still parses as
      # a cron entry; prose comments stay prose.
      def parse_commented_entry(stripped, system:)
        parse_active_entry(stripped.sub(/\A#+\s*/, ""), system: system)
      rescue StandardError
        nil
      end

      def vixie_entry?(tokens)
        return false if tokens.length < 6

        tokens[0..4].all? { |token| cron_field?(token) }
      end

      def parse_anacron_entry(stripped)
        return nil if stripped.empty? || stripped.start_with?("#")
        return nil if env_assignment?(stripped)

        tokens = stripped.split(/\s+/)
        return nil unless tokens.length >= 4
        return nil unless tokens[0].match?(ANACRON_PERIOD)
        return nil unless tokens[1].match?(/\A\d+\z/)
        return nil unless tokens[2].match?(/\A[A-Za-z0-9_.-]+\z/)

        job(
          command: tokens[3..].join(" "),
          schedule: "#{tokens[0]} #{tokens[1]} #{tokens[2]}",
          period: tokens[0],
          user: nil,
          kind: "anacron",
          name: tokens[2],
          delayMinutes: tokens[1].to_i
        )
      end

      # ------------------------------------------------------------ decoration

      def job(command:, schedule:, period:, user:, kind: "cron", name: nil, delayMinutes: nil)
        {
          kind: kind,
          schedule: schedule,
          period: period,
          command: command,
          user: user,
          name: name,
          delayMinutes: delayMinutes,
          commented: false,
          privilege: command.to_s.start_with?("sudo ") ? "sudo" : nil,
          lastRun: nil,
          nextAt: nil,
          nextLabel: nil
        }
      end

      def decorate(entry, now)
        if entry[:kind] == "anacron"
          decorate_anacron(entry, {})
          return
        end

        next_at = CronCalc.next_run(entry[:schedule], now)
        entry[:nextAt] = next_at&.utc&.iso8601
        entry[:nextLabel] = next_at ? humanize_delta(next_at - now) : "unsatisfiable"
      end

      def decorate_anacron(entry, spool)
        if (last = spool[entry[:name].to_s])
          entry[:lastRun] = last.strftime("%Y-%m-%d")
          next_at = anacron_next_run(entry, last, Time.now)
          entry[:nextAt] = next_at&.utc&.iso8601
          entry[:nextLabel] = next_at ? humanize_delta(next_at - Time.now) : nil
        else
          entry[:nextLabel] = "after start (delay #{entry[:delayMinutes].to_i}m)"
        end
      end

      def anacron_next_run(entry, last, now)
        days = anacron_period_days(entry[:period])
        return nil if days.nil?

        candidate = last + (days * 86_400)
        candidate = now if candidate < now
        candidate + start_hour_offset(entry) + (entry[:delayMinutes].to_i * 60)
      end

      def anacron_period_days(period)
        case period
        when /\A\d+\z/ then period.to_i
        when "@daily" then 1
        when "@weekly" then 7
        when "@monthly" then 30
        when "@yearly" then 365
        end
      end

      def start_hour_offset(entry)
        range = anacron_start_hours
        return 0 unless range

        hour = range.begin
        offset = (hour - Time.now.hour) * 3600
        offset.positive? ? offset : 0
      end

      def anacron_start_hours
        content = File.read(surface_paths["anacron"])
        match = content.match(/^START_HOURS_RANGE=(\d+)-(\d+)/)
        return nil unless match

        (match[1].to_i...match[2].to_i)
      rescue StandardError
        nil
      end

      # ------------------------------------------------------------ helpers

      def assign_ids(jobs)
        counts = Hash.new(0)
        jobs.each do |job|
          base = job[:name] ? "#{job[:surface]}:#{job[:name]}" : job[:surface].to_s
          counts[base] += 1
          job[:id] = counts[base] == 1 ? base : "#{base}@#{counts[base]}"
        end
        jobs
      end

      def env_assignment?(stripped)
        stripped.match?(/\A[A-Za-z_][A-Za-z0-9_]*\s*=/)
      end

      # Matches one vixie field: star, number, name, range, list, or any of
      # those with a step. Words like "solverforge-bench" or "nightly" fail, so
      # prose comments never become jobs.
      def cron_field?(token)
        return false unless token.is_a?(String)

        token.split(",").all? do |part|
          base = part.split("/", 2)[0]
          base == "*" ||
            base.match?(/\A\d+\z/) ||
            base.match?(/\A\d+-\d+\z/) ||
            base.match?(/\A[a-z]{3}(?:-[a-z]{3})?\z/i)
        end
      end

      def error(context, message)
        { code: "collect", context: context.to_s, message: message }
      end

      def locked_error(context, path)
        { code: "surface-locked", context: context.to_s,
          message: "locked: run `sudo cat #{path}` as root to grant visibility" }
      end

      def humanize_delta(seconds)
        return "now" if seconds <= 59

        minutes = (seconds / 60.0).round
        return "in #{minutes}m" if minutes < 60

        hours = minutes / 60
        return "in #{hours}h #{minutes % 60}m" if hours < 48

        "in #{hours / 24}d"
      end

      # ---------------------------------------------------------- cron calc

      # Computes the next firing time of a vixie schedule. Follows cron's OR
      # rule: the job runs when dom and dow both match (not their AND).
      module CronCalc
        module_function

        MAX_MINUTES = 366 * 24 * 60

        def next_run(schedule, from = Time.now)
          return reboot_schedule?(schedule) ? nil : special_next_run(schedule, from) if schedule.start_with?("@")

          fields = schedule.split(/\s+/)
          return nil unless fields.length == 5

          minute, hour, dom, month, dow = fields
          start = Time.at(from.to_i + 60)
          MAX_MINUTES.times do
            unless month_match?(start, month)
              advance = seconds_to_next_month(start)
              start = Time.at(start.to_i + advance)
              start = Time.at(start.to_i - start.sec).getlocal
              next
            end
            unless day_match?(start, dom, dow)
              start = Time.at(start.to_i + 86_400)
              start = Time.at(start.to_i - start.sec - start.min * 60 - start.hour * 3600).getlocal
              next
            end
            unless hour_match?(start, hour)
              start = Time.at(start.to_i + 3600)
              start = Time.at(start.to_i - start.sec - start.min * 60).getlocal
              next
            end
            return start if minute_match?(start, minute)

            start = Time.at(start.to_i + 60)
          end
          nil
        end

        def reboot_schedule?(schedule)
          schedule == "@reboot"
        end

        def special_next_run(schedule, from)
          step_days = { "@yearly" => 365, "@annually" => 365, "@monthly" => 30, "@weekly" => 7,
                        "@daily" => 1, "@midnight" => 1 }.freeze
          return nil if schedule == "@reboot"

          if schedule == "@hourly"
            t = from + 3600
            return Time.at(t.to_i - t.sec - t.min * 60).getlocal
          end

          days = step_days[schedule]
          return nil unless days

          target = from + (days * 86_400)
          Time.at(target.to_i - target.sec - target.min * 60 - target.hour * 3600).getlocal
        end

        def month_match?(time, month)
          field_match?(month, time.month, 1..12)
        end

        def day_match?(time, dom, dow)
          dom_match = field_match?(dom, time.day, 1..31)
          dow_match = field_match?(dow, time.wday, 0..7)
          restricted_dom = dom != "*"
          restricted_dow = dow != "*"
          if restricted_dom && restricted_dow
            dom_match || dow_match
          else
            dom_match && dow_match
          end
        end

        def hour_match?(time, hour)
          field_match?(hour, time.hour, 0..23)
        end

        def minute_match?(time, minute)
          field_match?(minute, time.min, 0..59)
        end

        def field_match?(field, value, range)
          field.split(",").any? do |part|
            base, step = part.split("/", 2)
            step = step&.to_i
            matches =
              if base == "*"
                range.cover?(value)
              elsif (match = base.match(/\A(\d+)-(\d+)\z/))
                (match[1].to_i..match[2].to_i).cover?(value)
              elsif base.match?(/\A\d+\z/)
                base.to_i == value || (range == (0..7) && base.to_i == 7 && value.zero?)
              else
                false
              end
            next matches if step.nil? || step.zero?

            anchor = base == "*" ? range.begin : (base.match(/\A(\d+)/) || [nil, range.begin])[1].to_i
            matches && (value - anchor) % step == 0
          end
        end

        def seconds_to_next_month(time)
          month = time.month == 12 ? 1 : time.month + 1
          year = time.month == 12 ? time.year + 1 : time.year
          target = Time.new(year, month, 1, 0, 0, 0, time.utc_offset)
          target.to_i - time.to_i
        end
      end
    end
  end
end
