# frozen_string_literal: true

require_relative "test_helper"

module Cronbar
  module Core
    class ConfigTest < Minitest::Test
      include CronbarTestHelpers

      def test_default_config_is_valid
        assert_empty Cronbar::Core::Config.validate_config(Cronbar::Core::Config.default_config)
      end

      def test_init_writes_config_with_family_defaults
        with_temp_home do |home|
          path = File.join(home, ".config", "cronbar", "config.json")
          config = Cronbar::Core::Config.init_config(path)

          assert File.file?(path)
          assert_equal 14, config.dig(:runtime, :waybarSignal)
          assert_equal 300, config.dig(:runtime, :refreshSeconds)
          assert_equal File.join(home, ".local", "state", "cronbar"), config.dig(:runtime, :stateDir)
          assert_equal({ user: true, system: true, cronD: true, anacron: true, commented: true }, config[:surfaces])
          assert_equal config, Cronbar::Core::Config.load_config(path)
        end
      end

      def test_partial_configs_merge_with_defaults
        config = Cronbar::Core::Config.normalize_config(
          runtime: { refreshSeconds: 600 },
          surfaces: { commented: false }
        )

        assert_equal 600, config.dig(:runtime, :refreshSeconds)
        assert_equal 14, config.dig(:runtime, :waybarSignal)
        assert_equal false, config.dig(:surfaces, :commented)
        assert_equal true, config.dig(:surfaces, :user)
      end

      def test_validation_rejects_out_of_range_and_unknown_values
        issues = Cronbar::Core::Config.validate_config(
          Cronbar::Core::Config.normalize_config(
            runtime: { refreshSeconds: 1, waybarSignal: 32 },
            surfaces: { commented: "sometimes", bogus: true }
          )
        )

        fields = issues.map { |issue| issue[:field] }
        assert_includes fields, "runtime.refreshSeconds"
        assert_includes fields, "runtime.waybarSignal"
        assert_includes fields, "surfaces.commented"
        assert_includes fields, "surfaces.bogus"
        assert issues.all? { |issue| issue[:severity] == "error" }
      end

      def test_load_raises_a_readable_error_on_invalid_json
        with_temp_home do |home|
          path = File.join(home, "broken.json")
          File.write(path, "{not json")

          error = assert_raises(RuntimeError) { Cronbar::Core::Config.load_config(path) }
          assert_match(/Invalid cronbar config/, error.message)
        end
      end
    end
  end
end
