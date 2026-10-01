# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module Core
    class CollectorsTest < Minitest::Test
      include CronbarTestHelpers

      def setup
        @root = Dir.mktmpdir
        @paths = {
          "user" => File.join(@root, "user-crontab"),
          "sys" => File.join(@root, "system-crontab"),
          "cron.d" => File.join(@root, "cron.d"),
          "anacron" => File.join(@root, "anacrontab"),
          "anacron-spool" => File.join(@root, "spool")
        }
        FileUtils.mkdir_p(@paths["cron.d"])
        FileUtils.mkdir_p(@paths["anacron-spool"])
        File.write(@paths["user"], "")
        Cronbar::Core::Collectors.surface_paths = @paths
      end

      def teardown
        Cronbar::Core::Collectors.surface_paths = Cronbar::Core::Collectors::DEFAULT_SURFACE_PATHS
        FileUtils.remove_entry(@root) if @root && File.directory?(@root)
      end

      def config
        @config ||= temp_config(File.join(@root, "state"))
      end

      def test_missing_anacrontab_is_reported_not_raised
        collected = Cronbar::Core::Collectors.scan(config)

        assert_empty collected[:jobs]
        assert collected[:errors].any? { |e| e[:context] == "anacron" }
      end

      def test_user_crontab_parses_special_schedules_sudo_and_comments
        File.write(@paths["user"], sample_crontab)
        collected = Cronbar::Core::Collectors.scan(config)

        jobs = collected[:jobs]
        assert_equal 5, jobs.length

        hourly = jobs.find { |j| j[:schedule] == "@hourly" }
        assert_equal "sudo mount -a", hourly[:command]

        sudo_job = jobs.find { |j| j[:command].start_with?("sudo mount") }
        assert_equal "sudo", sudo_job[:privilege]

        commented = jobs.find { |j| j[:commented] }
        assert_equal "echo ghost", commented[:command]
        assert commented[:nextAt]
        assert commented[:nextLabel]

        numbered = jobs.select { |j| j[:id].start_with?("user@") }
        assert_equal 4, numbered.length
      end

      def test_env_lines_and_prose_comments_are_never_jobs
        File.write(@paths["user"], <<~CRONTAB)
          PATH=/usr/bin:/bin
          MAILTO=admin@example.com
          # this is prose about why the job is off
          # 0 4 * * * echo real commented job
          0 6 * * * echo active
        CRONTAB
        collected = Cronbar::Core::Collectors.scan(config)

        jobs = collected[:jobs]
        assert_equal 2, jobs.length
        assert_equal "echo real commented job", jobs[0][:command]
        assert jobs[0][:commented]
        assert_equal "echo active", jobs[1][:command]
        refute jobs[1][:commented]
      end

      def test_system_crontab_requires_user_column
        File.write(@paths["sys"], <<~CRONTAB)
          # a commented system entry
          15 3 * * * backup-operator /usr/local/bin/backup.sh
        CRONTAB
        collected = Cronbar::Core::Collectors.scan(config)

        sys = collected[:jobs].select { |j| j[:surface] == "sys" }
        assert_equal 1, sys.length
        assert_equal "backup-operator", sys[0][:user]
        assert_equal "/usr/local/bin/backup.sh", sys[0][:command]
        assert_equal "15 3 * * *", sys[0][:schedule]
      end

      def test_special_system_schedules_separate_the_user_from_the_command
        ["sys", "cron.d"].each do |surface|
          jobs = Collectors.parse_crontab("@hourly root run-parts /etc/cron.hourly\n", surface: surface, source: "fixture", system: true)
          assert_equal 1, jobs.length
          assert_equal "root", jobs.first[:user]
          assert_equal "run-parts /etc/cron.hourly", jobs.first[:command]
          assert_empty Collectors.parse_crontab("@hourly root\n", surface: surface, source: "fixture", system: true)
        end
      end

      def test_cron_d_files_group_under_their_file_name
        File.write(File.join(@paths["cron.d"], "backup-sync"), "0 2 * * * root rsync -a /srv /backup\n")
        File.write(File.join(@paths["cron.d"], "weird name"), "# not a valid cron.d filename\n")

        collected = Cronbar::Core::Collectors.scan(config)
        job = collected[:jobs].find { |j| j[:surface] == "cron.d" }

        assert_equal "cron.d:backup-sync", job[:id]
        assert_equal "root", job[:user]
        assert_equal "backup-sync", job[:name]
      end

      def test_anacron_jobs_carry_identifier_delay_and_spool_timestamps
        File.write(@paths["anacron"], sample_anacrontab)
        File.write(File.join(@paths["anacron-spool"], "cron.daily"), "20261001\n")
        File.write(File.join(@paths["anacron-spool"], "cron.weekly"), "garbage\n")

        collected = Cronbar::Core::Collectors.scan(config)
        jobs = collected[:jobs]

        assert_equal 3, jobs.length
        daily = jobs.find { |j| j[:name] == "cron.daily" }
        assert_equal "anacron:cron.daily", daily[:id]
        assert_equal 5, daily[:delayMinutes]
        assert_equal "2026-10-01", daily[:lastRun]
        assert daily[:nextLabel].include?("in ")

        weekly = jobs.find { |j| j[:name] == "cron.weekly" }
        assert_equal "after start (delay 25m)", weekly[:nextLabel]

        monthly = jobs.find { |j| j[:name] == "cron.monthly" }
        assert_equal "@monthly 45 cron.monthly", monthly[:schedule]
      end

      def test_anacron_commented_entries_are_collected_as_commented
        File.write(@paths["anacron"], "#{sample_anacrontab}# 1\t10\tcron.daily\t\techo ghost\n")

        collected = Cronbar::Core::Collectors.scan(config)
        ghost = collected[:jobs].find { |j| j[:name] == "cron.daily" && j[:commented] }

        assert_equal "echo ghost", ghost[:command]
      end

      def test_disabled_commented_surface_drops_commented_jobs
        File.write(@paths["user"], sample_crontab)
        config = Cronbar::Core::Config.normalize_config(surfaces: { commented: false })

        collected = Cronbar::Core::Collectors.scan(config)

        refute collected[:jobs].any? { |j| j[:commented] }
        assert_equal 4, collected[:jobs].length
      end

      def test_assign_ids_deduplicates_duplicate_names
        jobs = [
          cron_job(surface: "cron.d", name: "dupe"),
          cron_job(surface: "cron.d", name: "dupe"),
          cron_job(surface: "cron.d", name: "dupe")
        ]

        ids = Cronbar::Core::Collectors.assign_ids(jobs).map { |j| j[:id] }

        assert_equal ["cron.d:dupe", "cron.d:dupe@2", "cron.d:dupe@3"], ids
      end

      # ------------------------------------------------------------ cron calc

      def test_next_run_hourly_special
        from = Time.new(2026, 10, 1, 10, 15, 30)
        next_at = Cronbar::Core::Collectors::CronCalc.next_run("@hourly", from)

        assert_equal Time.new(2026, 10, 1, 11, 0, 0), next_at
      end

      def test_next_run_daily_morning
        from = Time.new(2026, 10, 1, 10, 0, 0)
        next_at = Cronbar::Core::Collectors::CronCalc.next_run("30 4 * * *", from)

        assert_equal Time.new(2026, 10, 2, 4, 30, 0), next_at
      end

      def test_next_run_weekday_range_skips_weekend
        friday = Time.new(2026, 10, 2, 12, 0, 0)
        monday = Cronbar::Core::Collectors::CronCalc.next_run("0 9 * * 1-5", friday)

        assert_equal Time.new(2026, 10, 5, 9, 0, 0), monday
      end

      def test_next_run_uses_cron_dom_or_dow_semantics
        # Oct 2026: the 13th is a Tuesday, Fridays are the 2nd/9th/... Under
        # cron's OR rule the next firing of "0 12 13 * 5" from Thu Oct 1 is
        # Friday Oct 2. An AND implementation would wrongly wait for Nov 13
        # (the only 13th-that-is-a-Friday in reach).
        from = Time.new(2026, 10, 1, 12, 0, 0)
        next_at = Cronbar::Core::Collectors::CronCalc.next_run("0 12 13 * 5", from)

        assert_equal Time.new(2026, 10, 2, 12, 0, 0), next_at
        refute_equal Time.new(2026, 11, 13, 12, 0, 0), next_at
      end

      def test_next_run_step_minutes
        from = Time.new(2026, 10, 1, 10, 7, 0)
        next_at = Cronbar::Core::Collectors::CronCalc.next_run("*/15 * * * *", from)

        assert_equal Time.new(2026, 10, 1, 10, 15, 0), next_at
      end

      def test_next_run_crosses_year_and_handles_leap_day
        from = Time.new(2026, 12, 31, 23, 30, 0)
        new_year = Cronbar::Core::Collectors::CronCalc.next_run("0 0 1 1 *", from)

        assert_equal Time.new(2027, 1, 1, 0, 0, 0), new_year

        from = Time.new(2028, 2, 28, 12, 0, 0)
        leap = Cronbar::Core::Collectors::CronCalc.next_run("0 0 29 2 *", from)

        assert_equal Time.new(2028, 2, 29, 0, 0, 0), leap
      end

      def test_next_run_rejects_unparseable_schedules
        assert_nil Cronbar::Core::Collectors::CronCalc.next_run("not a schedule")
        assert_nil Cronbar::Core::Collectors::CronCalc.next_run("* * *")
      end

      private

      def sample_crontab
        <<~CRONTAB
          @daily echo daily
          @hourly sudo mount -a
          0 3 * * 1-5 echo weekdays
          # 0 4 * * * echo ghost
          30 2 1 * * echo monthly-ish
        CRONTAB
      end

      def sample_anacrontab
        <<~ANACRONTAB
          SHELL=/bin/sh
          RANDOM_DELAY=45
          START_HOURS_RANGE=3-22

          1\t5\tcron.daily\t\tnice run-parts /etc/cron.daily
          7\t25\tcron.weekly\t\tnice run-parts /etc/cron.weekly
          @monthly 45\tcron.monthly\t\tnice run-parts /etc/cron.monthly
        ANACRONTAB
      end
    end
  end
end
