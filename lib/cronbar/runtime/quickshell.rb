# frozen_string_literal: true

require "time"

module Cronbar
  module Runtime
    module QuickShell
      module_function

      def open(config_path)
        config = Core::Config.load_config(config_path)
        State.write_ui_state(config, { open: true, requestedAt: Time.now.utc.iso8601 })
        launch(config_path, config)
      end

      def close(config_path)
        config = Core::Config.load_config(config_path)
        State.write_ui_state(config, { open: false, requestedAt: Time.now.utc.iso8601 })
      end

      def toggle(config_path)
        config = Core::Config.load_config(config_path)
        current = State.read_ui_state(config)
        current[:open] ? close(config_path) : open(config_path)
        State.read_ui_state(config)
      end

      def status(config_path)
        config = Core::Config.load_config(config_path)
        State.read_ui_state(config)
      end

      def launch(config_path, config = nil)
        config ||= Core::Config.load_config(config_path)
        shell = File.expand_path(config.dig(:runtime, :quickShellShell).to_s)
        command = config.dig(:runtime, :quickShellCommand).to_s
        env = {
          "CRONBAR_BIN" => resolved_binary,
          "CRONBAR_CONFIG" => File.expand_path(config_path),
          "CRONBAR_STATE_DIR" => State.state_dir(config),
          "QT_QPA_PLATFORM" => "wayland"
        }

        Core::Process.run_command(command, ["--daemonize", "--no-duplicate", "--path", shell], timeout: 5, env: env)
      end

      def resolved_binary
        candidates = [
          ENV["CRONBAR_BIN"],
          File.join(Dir.home, ".local", "bin", "cronbar"),
          File.expand_path("../../../bin/cronbar", __dir__),
          "cronbar"
        ].compact

        candidates.find { |candidate| candidate == "cronbar" || File.executable?(candidate) } || "cronbar"
      end
    end
  end
end
