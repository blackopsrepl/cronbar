# frozen_string_literal: true

require "digest"
require "json"
require "openssl"

module Cronbar
  module CLI
    module_function

    def run(argv = ARGV)
      command = argv.first&.start_with?("-") ? "help" : (argv.shift || "help")
      args = parse_args(argv)
      config_path = args[:config] || Core::Config.default_config_path

      case command
      when "config"
        run_config_command(args, config_path)
      when "daemon"
        Runtime::Daemon.run(config_path, once: args[:once])
        0
      when "help"
        puts usage
        0
      when "panel"
        Runtime::QuickShell.open(config_path)
        0
      when "refresh"
        snapshot = Runtime::Daemon.refresh(config_path)
        print_json_if_requested(snapshot, args)
        0
      when "run"
        run_run_command(args, config_path)
      when "runs"
        runs = Runtime::State.read_runs(Core::Config.load_config(config_path))
        print_json(runs, args)
        0
      when "snapshot"
        snapshot = Runtime::Daemon.refresh(config_path)
        print_json(snapshot, args)
        0
      when "ui"
        run_ui_command(args, config_path)
      when "waybar"
        run_waybar_command(args, config_path)
      when "omarchy"
        run_omarchy_command(args, config_path)
      else
        raise ArgumentError, "Unknown command: #{command}"
      end
    rescue StandardError => e
      warn e.message
      1
    end

    def parse_args(argv)
      args = { format: "text", once: false, pretty: false, positionals: [], limit: 50 }
      index = 0

      while index < argv.length
        value = argv[index]
        case value
        when "--config"
          index += 1
          args[:config] = argv[index]
        when "--format"
          index += 1
          args[:format] = argv[index] == "json" ? "json" : "text"
        when "--pretty"
          args[:pretty] = true
        when "--once"
          args[:once] = true
        when "--pass"
          index += 1
          args[:pass] = argv[index]
        when "--yes"
          args[:yes] = true
        when "--dry-run"
          args[:dry_run] = true
        when "--limit"
          index += 1
          args[:limit] = argv[index]
        when "--section"
          index += 1
          args[:section] = argv[index]
        when "--index"
          index += 1
          args[:index] = argv[index]
        when "--interval"
          index += 1
          args[:interval] = argv[index]
        when "--exec"
          index += 1
          args[:exec] = argv[index]
        else
          args[:positionals] << value
        end
        index += 1
      end

      args
    end

    # --------------------------------------------------------------- run gate

    def run_run_command(args, config_path)
      id = args[:positionals].shift
      raise ArgumentError, "usage: cronbar run <job-id> [--pass <passphrase>] [--yes] [--dry-run]" unless id

      return run_with_prompt(args, config_path, id) if args[:yes]

      pass = args[:pass] || ENV["CRONBAR_RUN_PASS"]
      unless pass
        warn "cronbar run: refusing to execute without the run passphrase."
        warn "usage: cronbar run <job-id> --pass <passphrase>   (or --yes for a terminal prompt)"
        return 1
      end

      execute_run(args, config_path, id, pass)
    end

    def run_with_prompt(args, config_path, id)
      require "io/console"
      $stdout.print("run passphrase for cronbar (jobs run as you, sudo jobs may prompt): ")
      $stdout.flush
      pass = $stdin.noecho(&:gets)&.chomp
      $stdout.puts
      unless pass
        warn "\ncronbar run: aborted."
        return 1
      end

      execute_run(args, config_path, id, pass)
    end

    def execute_run(args, config_path, id, pass)
      unless gate(pass)
        warn "cronbar run: wrong passphrase."
        return 2
      end

      config = Core::Config.load_config(config_path)
      snapshot = Runtime::State.read_snapshot(config)
      outcome = Runtime::Runner.run_job(config, snapshot, id, dry_run: args[:dry_run])
      return report_failure(outcome, args) unless outcome[:ok] || outcome[:dryRun]

      record = outcome[:record]
      if args[:format] == "json"
        print_json(record, args)
      else
        verb = outcome[:dryRun] ? "would run" : "ran"
        puts "#{verb} #{id} [#{record[:status]}#{record[:exitCode] ? " exit #{record[:exitCode]}" : ''}]"
        puts "  #{outcome[:job][:command]}"
        unless outcome[:dryRun]
          puts "  stdout: #{record[:stdout].to_s.empty? ? '(empty)' : record[:stdout]}"
          puts "  stderr: #{record[:stderr].to_s.empty? ? '(empty)' : record[:stderr]}"
        end
      end
      0
    end

    def gate(pass)
      expected = File.read(Cronbar::Core::Config.gate_path)
    rescue Errno::EACCES, Errno::ENOENT
      warn "cronbar run: #{Cronbar::Core::Config.gate_path} is missing or unreadable; create it first (see README)."
      false
    else
      hashed = Digest::SHA256.hexdigest("cronbar-run:#{pass}")
      fixed_digest?(expected.strip, hashed)
    end

    def fixed_digest?(expected, actual)
      expected.bytesize == actual.bytesize && OpenSSL.secure_compare(expected, actual)
    end

    def report_failure(outcome, args)
      if outcome[:error]
        warn "cronbar run: #{outcome[:error]}"
        return 1
      end

      record = outcome[:record]
      if args[:format] == "json"
        print_json(record, args)
      else
        warn "cronbar run: #{record[:status]}#{record[:exitCode] ? " exit #{record[:exitCode]}" : ''}"
        warn "  #{record[:stderr]}".squeeze("\n") unless record[:stderr].to_s.empty?
      end
      1
    end

    # ------------------------------------------------------------- commands

    def run_config_command(args, config_path)
      subcommand = args[:positionals].first || "validate"
      if subcommand == "init"
        print_json(Core::Config.init_config(config_path), args)
        return 0
      end

      config = Core::Config.load_config(config_path)
      issues = Core::Config.validate_config(config)
      if args[:format] == "json"
        print_json(issues, args)
      elsif issues.empty?
        puts "Config valid."
      else
        issues.each { |issue| puts "#{issue[:severity].upcase}: #{issue[:field]} #{issue[:message]}" }
      end
      issues.any? { |issue| issue[:severity] == "error" } ? 1 : 0
    end

    def run_ui_command(args, config_path)
      subcommand = args[:positionals].first || "open"
      payload = case subcommand
                when "open"
                  Runtime::QuickShell.open(config_path)
                  Runtime::QuickShell.status(config_path)
                when "close"
                  Runtime::QuickShell.close(config_path)
                  Runtime::QuickShell.status(config_path)
                when "toggle"
                  Runtime::QuickShell.toggle(config_path)
                when "status"
                  Runtime::QuickShell.status(config_path)
                else
                  raise ArgumentError, "Unknown ui subcommand: #{subcommand}"
                end
      print_json_if_requested(payload, args)
      0
    end

    def run_waybar_command(args, config_path)
      subcommand = args[:positionals].first || "render"
      case subcommand
      when "render"
        Runtime::Waybar.render(config_path)
      when "refresh"
        Runtime::Waybar.refresh(config_path)
      when "panel", "open"
        Runtime::Waybar.open_panel(config_path)
      else
        raise ArgumentError, "Unknown waybar subcommand: #{subcommand}"
      end
      0
    end

    def run_omarchy_command(args, config_path)
      subcommand = args[:positionals].first || "status"
      result = case subcommand
               when "install"
                 Runtime::Omarchy.install(
                   config_path,
                   after: args[:after],
                   section: args[:section],
                   index: args[:index],
                   interval: args[:interval] || Runtime::Omarchy::DEFAULT_INTERVAL,
                   bin: args[:exec]
                 )
               when "remove"
                 Runtime::Omarchy.remove
               when "status"
                 Runtime::Omarchy.status
               else
                 raise ArgumentError, "Unknown omarchy subcommand: #{subcommand}"
               end
      print_json_if_requested(result, args)
      unless args[:format] == "json"
        puts describe_omarchy_result(subcommand, result)
      end
      0
    end

    def describe_omarchy_result(subcommand, result)
      case subcommand
      when "install"
        "Installed #{Runtime::Omarchy::MODULE_ID} module in #{result[:shellConfig]} " \
          "(#{result[:section]}[#{result[:index]}], seeded from #{result[:seededFrom]})"
      when "remove"
        result[:removed] ? "Removed #{Runtime::Omarchy::MODULE_ID} module from #{result[:shellConfig]}" : result[:reason]
      else
        if result[:installed]
          "#{Runtime::Omarchy::MODULE_ID} module installed at #{result[:shellConfig]} " \
            "(#{result[:section]}[#{result[:index]}])"
        else
          "#{Runtime::Omarchy::MODULE_ID} module not installed"
        end
      end
    end

    def print_json_if_requested(payload, args)
      print_json(payload, args) if args[:format] == "json"
    end

    def print_json(payload, args)
      puts(args[:pretty] ? JSON.pretty_generate(payload) : JSON.generate(payload))
    end

    def usage
      <<~TEXT
        cronbar commands:
          config init|validate
          snapshot
          refresh
          run <job-id> --pass <passphrase>   run a job manually (commented ones too)
          run <job-id> --yes                 prompt for the passphrase on the terminal
          run <job-id> --pass ... --dry-run  show the command without executing
          runs                               recent manual runs
          daemon [--once]
          panel
          ui open|close|toggle|status
          waybar render|refresh|panel
          omarchy install|remove|status
      TEXT
    end
  end
end
