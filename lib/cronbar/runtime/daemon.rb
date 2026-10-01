# frozen_string_literal: true

module Cronbar
  module Runtime
    module Daemon
      module_function

      def run(config_path, once: false)
        config = Core::Config.load_config(config_path)
        return refresh(config_path, config: config) if once

        lock = State.acquire_daemon_lock(config)
        raise "cronbar daemon already running for #{State.state_dir(config)}." unless lock

        refresh(config_path, config: config)
        loop do
          sleep(config.dig(:runtime, :refreshSeconds).to_i)
          refresh(config_path, config: config)
        rescue StandardError => e
          warn "cronbar daemon refresh error: #{e.message}"
        end
      ensure
        lock&.close
      end

      def refresh(config_path, config: nil)
        config ||= Core::Config.load_config(config_path)
        snapshot = nil

        State.with_lock(config, State::REFRESH_LOCK_FILE) do
          snapshot =
            begin
              State.build_snapshot(config, Core::Collectors.scan(config))
            rescue StandardError => e
              State.build_error_snapshot(e.message)
            end
          State.write_snapshot(config, snapshot)
        end

        signal_waybar(config)
        snapshot
      end

      def signal_waybar(config)
        signal = config.dig(:runtime, :waybarSignal).to_i
        return if signal <= 0

        Core::Process.run_command("pkill", ["-RTMIN+#{signal}", "waybar"], timeout: 2)
      rescue StandardError
        nil
      end
    end
  end
end
