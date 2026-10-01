# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class IntegrationTest < Minitest::Test
  include CronbarTestHelpers

  def test_waybar_reads_cached_jobs_without_collecting_or_running
    with_temp_home do |home|
      config = temp_config(File.join(home, "state"))
      path = write_config(config, File.join(home, "config.json"))
      write_snapshot(config, [cron_job, cron_job(command: "echo commented", commented: true)])
      output = StringIO.new
      Cronbar::Core::Collectors.stub(:scan, ->(*) { flunk "render collected sources" }) do
        Cronbar::Runtime::Waybar.render(path, out: output)
      end
      chip = JSON.parse(output.string)
      assert_includes chip.fetch("text"), "1j"
      assert_includes chip.fetch("class"), "cronbar"
      assert_kind_of String, chip.fetch("tooltip")
      assert_empty Cronbar::Runtime::State.read_runs(config)[:runs]
    end
  end

  def test_omarchy_install_is_idempotent_and_remove_preserves_neighbors
    with_temp_home do |home|
      shell_path = File.join(home, ".config/omarchy/shell.json")
      FileUtils.mkdir_p(File.dirname(shell_path))
      original = { "bar" => { "layout" => { "center" => [{ "id" => "omarchy.weather" }] } } }
      File.write(shell_path, JSON.generate(original))
      bin = File.expand_path("../bin/cronbar", __dir__)
      Cronbar::Runtime::Omarchy.stub(:refresh_shell, nil) do
        2.times do
          result = Cronbar::Runtime::Omarchy.install(File.join(home, "config.json"), bin: bin)
          assert result[:installed]
        end
        document = JSON.parse(File.read(shell_path))
        entries = document.dig("bar", "layout", "center")
        assert_equal ["omarchy.weather", "cronbar"], entries.map { |entry| entry["id"] }
        assert_includes entries.last.fetch("exec"), "waybar render"
        assert_includes entries.last.fetch("onClick"), "panel"
        assert Cronbar::Runtime::Omarchy.status[:installed]
        assert Cronbar::Runtime::Omarchy.remove[:removed]
        assert_equal [{ "id" => "omarchy.weather" }], JSON.parse(File.read(shell_path)).dig("bar", "layout", "center")
      end
    end
  end
end
