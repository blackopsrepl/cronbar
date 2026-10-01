# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module Cronbar
  module Runtime
    # Mounts the cached-state Waybar chip as an Omarchy shell bar module so the
    # same render contract works on Hyprland desktops.
    module Omarchy
      module_function

      MODULE_ID = "cronbar"
      ANCHOR_ID = "omarchy.weather"
      FALLBACK_SECTION = "center"
      SECTIONS = %w[left center right].freeze
      DEFAULT_INTERVAL = 300
      DEFAULT_BIN = File.expand_path("../../../bin/cronbar", __dir__)

      def install(config_path, after: nil, section: nil, index: nil, interval: DEFAULT_INTERVAL, bin: nil)
        interval = normalize_interval(interval)
        bin = resolve_bin(bin)

        document, source = load_shell_document
        normalize_document!(document)
        entry = module_entry(bin, interval, config_path)
        location = place!(document, entry, after: after, section: section, index: index)
        save_shell_document(document)
        refresh_shell

        { installed: true, seededFrom: source, shellConfig: shell_config_path,
          section: location[:section], index: location[:index], entry: entry }.tap do |result|
          result[:fallback] = true if location[:fallback]
        end
      end

      def remove
        path = shell_config_path
        unless File.size?(path)
          return { removed: false, shellConfig: path, reason: "user shell config not found" }
        end

        document = parse_json(path)
        normalize_document!(document)
        removed = delete_module_entries!(document)
        return { removed: false, shellConfig: path, reason: "module not installed" } unless removed.positive?

        save_shell_document(document)
        refresh_shell
        { removed: true, shellConfig: path }
      end

      def status
        path = shell_config_path
        document = File.size?(path) ? parse_json(path) : nil
        location = document ? find_module(document) : nil

        { installed: !location.nil?, shellConfig: path, section: location&.fetch(:section),
          index: location&.fetch(:index), entry: location&.fetch(:entry) }
      end

      # ------------------------------------------------------------ internals

      def shell_config_path
        File.join(Dir.home, ".config", "omarchy", "shell.json")
      end

      def defaults_path
        File.join(ENV.fetch("OMARCHY_PATH", "/usr/share/omarchy"), "config", "omarchy", "shell.json")
      end

      def load_shell_document
        user_path = shell_config_path
        return [parse_json(user_path), "user"] if File.size?(user_path)

        defaults = defaults_path
        raise "Omarchy shell defaults not found at #{defaults}; cannot seed shell config" unless File.size?(defaults)

        [parse_json(defaults), "defaults"]
      end

      def parse_json(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise "Invalid Omarchy shell config #{path}: #{e.message}"
      end

      def normalize_document!(document)
        raise "Omarchy shell config must be a JSON object" unless document.is_a?(Hash)

        document["version"] = 1 unless document["version"].is_a?(Integer)
        bar = document["bar"] = document.fetch("bar", {})
        raise "Omarchy shell config bar must be an object" unless bar.is_a?(Hash)

        layout = bar["layout"] = bar.fetch("layout", {})
        raise "Omarchy shell config bar.layout must be an object" unless layout.is_a?(Hash)

        SECTIONS.each do |name|
          section = layout[name] = layout.fetch(name, [])
          raise "Omarchy shell config bar.layout.#{name} must be an array" unless section.is_a?(Array)
        end
        plugins = document["plugins"] = document.fetch("plugins", [])
        raise "Omarchy shell config plugins must be an array" unless plugins.is_a?(Array)

        document
      end

      def module_entry(bin, interval, config_path)
        quoted = Shellwords.escape(bin)
        config = Shellwords.escape(File.expand_path(config_path))
        {
          "id" => MODULE_ID,
          "type" => "command",
          "exec" => "#{quoted} waybar render --config #{config}",
          "interval" => interval,
          "onClick" => "#{quoted} panel --config #{config}",
          "onMiddleClick" => "#{quoted} refresh --config #{config}",
          "tooltip" => "cronbar scheduled-jobs chip (left: panel, middle: refresh)"
        }
      end

      def place!(document, entry, after:, section:, index:)
        delete_module_entries!(document)

        if section
          raise ArgumentError, "section must be left, center, or right" unless SECTIONS.include?(section)

          entries = document["bar"]["layout"][section]
          at = index.nil? ? entries.length : Integer(index)
          raise ArgumentError, "index must be a non-negative integer" if at.negative?
          if at > entries.length
            raise ArgumentError, "index #{at} is past the end of the #{section} section (0..#{entries.length})"
          end

          entries.insert(at, entry)
          return { section: section, index: at }
        end

        anchor = after || ANCHOR_ID
        SECTIONS.each do |name|
          entries = document["bar"]["layout"][name]
          at = entries.index { |item| item.is_a?(Hash) && item["id"] == anchor }
          next if at.nil?

          document["bar"]["layout"][name].insert(at + 1, entry)
          return { section: name, index: at + 1 }
        end

        section = document["bar"]["layout"][FALLBACK_SECTION]
        section << entry
        { section: FALLBACK_SECTION, index: section.length - 1, fallback: true }
      end

      def delete_module_entries!(document)
        count = 0
        SECTIONS.each do |name|
          entries = document["bar"]["layout"][name]
          entries.reject! do |item|
            next false unless item.is_a?(Hash) && item["id"] == MODULE_ID

            count += 1
            true
          end
        end
        count
      end

      def find_module(document)
        SECTIONS.each do |name|
          entries = document.dig("bar", "layout", name)
          next unless entries.is_a?(Array)

          entries.each_with_index do |item, at|
            next unless item.is_a?(Hash) && item["id"] == MODULE_ID

            return { section: name, index: at, entry: item }
          end
        end
        nil
      end

      def save_shell_document(document)
        path = shell_config_path
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        temp = "#{path}.#{::Process.pid}.tmp"
        File.write(temp, JSON.pretty_generate(document) + "\n")
        File.rename(temp, path)
      rescue StandardError
        File.delete(temp) if File.exist?(temp)
        raise
      end

      def refresh_shell
        pid = ::Process.spawn("omarchy-shell", "shell", "reloadConfig",
                              out: File::NULL, err: File::NULL)
        ::Process.detach(pid)
      rescue StandardError
        nil
      end

      def resolve_bin(bin)
        candidate = bin || DEFAULT_BIN
        candidate = File.expand_path(candidate)
        return candidate if File.executable?(candidate)

        raise "cronbar binary not found or not executable: #{candidate}"
      end

      def normalize_interval(interval)
        value = Integer(interval)
        raise ArgumentError, "interval must be a positive integer" if value <= 0

        value
      end
    end
  end
end
