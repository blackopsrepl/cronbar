# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "cronbar"

module CronbarTestHelpers
  def with_temp_home
    Dir.mktmpdir do |dir|
      old_home = ENV["HOME"]
      ENV["HOME"] = dir
      yield dir
    ensure
      ENV["HOME"] = old_home
    end
  end

  # A normalized config pointed at a throwaway state dir.
  def temp_config(state_dir)
    Cronbar::Core::Config.normalize_config(runtime: { stateDir: state_dir })
  end

  def write_config(config, path)
    Cronbar::Core::Config.save_config(config, path)
    path
  end

  # The run-gate pass file lives outside the checkout; tests point
  # Cronbar::Core::Config.gate_path at a temp copy.
  def with_gate_pass(pass)
    file = File.join(Dir.mktmpdir, "run.pass")
    digest = Digest::SHA256.hexdigest("cronbar-run:#{pass}")
    File.write(file, "#{digest}\n")
    old_path = Cronbar::Core::Config.gate_path
    Cronbar::Core::Config.gate_path = file
    yield file
  ensure
    Cronbar::Core::Config.gate_path = old_path
  end

  # -------------------------------------------------------- job factories

  def cron_job(overrides = {})
    {
      kind: "cron",
      schedule: "30 4 * * *",
      period: nil,
      command: "echo hello",
      user: nil,
      name: nil,
      delayMinutes: nil,
      commented: false,
      privilege: nil,
      readPrivilege: nil,
      lastRun: nil,
      nextAt: "2026-10-02T02:30:00Z",
      nextLabel: "in 12h",
      surface: "user",
      source: "crontab -l",
      line: 1,
      id: "user"
    }.merge(overrides)
  end

  def anacron_job(overrides = {})
    cron_job(
      {
        kind: "anacron",
        schedule: "1 5 cron.daily",
        period: "1",
        command: "nice run-parts /etc/cron.daily",
        name: "cron.daily",
        delayMinutes: 5,
        surface: "anacron",
        source: "/etc/anacrontab",
        id: "anacron:cron.daily",
        nextLabel: "after start (delay 5m)"
      }.merge(overrides)
    )
  end

  def write_snapshot(config, jobs, errors: [])
    collected = { jobs: Cronbar::Core::Collectors.assign_ids(jobs), errors: errors }
    snapshot = Cronbar::Runtime::State.build_snapshot(config, collected)
    Cronbar::Runtime::State.write_snapshot(config, snapshot)
    snapshot
  end
end
