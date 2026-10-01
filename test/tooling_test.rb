# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class ToolingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_tool(root, *args, env: {})
    Open3.capture3(env, RbConfig.ruby, File.join(root, "bin/release-check"), *args)
  end

  def with_tool_tree
    Dir.mktmpdir("cronbar-tooling-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.cp(File.join(ROOT, "bin/release-check"), File.join(dir, "bin")) if File.file?(File.join(ROOT, "bin/release-check"))
      File.write(File.join(dir, "bin/cronbar"), "#!/usr/bin/env ruby\nputs 'ok'\n")
      yield dir
    end
  end

  def test_isolated_install_cli_and_archive_smoke
    out, err, status = run_tool(ROOT, "--smoke")
    assert status.success?, out + err
    assert_includes out, "isolated CLI/install/archive smoke passed"
  end

  def test_release_notes_extract_exact_version_and_fail_closed
    Dir.mktmpdir("cronbar-notes-") do |dir|
      changelog = File.join(dir, "CHANGELOG.md")
      File.write(changelog, "# Changelog\n\n## [1.0.0](https://example.invalid/compare/v0.1.0...v1.0.0)\nWrong release\n\n### [0.1.0](https://example.invalid/compare/v0.0.0...v0.1.0) (2026-01-01)\n\n### Features\n* actual change\n\n## 0.0.1 (2025-01-01)\nOld change\n")
      command = [RbConfig.ruby, File.join(ROOT, "bin/release-notes")]
      out, err, status = Open3.capture3(*command, "v0.1.0", changelog)
      assert status.success?, out + err
      assert_includes out, "actual change"
      refute_includes out, "Wrong release"
      refute_includes out, "Old change"
      _out, _err, status = Open3.capture3(*command, "v9.0.0", changelog)
      refute status.success?
      File.write(changelog, "# 0.1.0 (2026-01-01)\n\n")
      _out, _err, status = Open3.capture3(*command, "v0.1.0", changelog)
      refute status.success?
    end
  end

  def test_install_refuses_unowned_destination_and_broken_symlink
    Dir.mktmpdir("cronbar-install-safety-") do |dir|
      app = File.join(dir, "share/cronbar")
      bins = File.join(dir, "bin")
      env = { "APP_HOME" => app, "BIN_DIR" => bins }
      FileUtils.mkdir_p(app)
      File.write(File.join(app, "keep"), "unrelated")
      out, err, status = run_tool(ROOT, "--install", env: env)
      refute status.success?, out + err
      assert_equal "unrelated", File.read(File.join(app, "keep"))
      FileUtils.rm_rf(app)
      FileUtils.mkdir_p(bins)
      link = File.join(bins, "cronbar")
      File.symlink(File.join(dir, "unrelated-missing"), link)
      out, err, status = run_tool(ROOT, "--install", env: env)
      refute status.success?, out + err
      assert_equal File.join(dir, "unrelated-missing"), File.readlink(link)
    end
  end

  def test_wrapper_upgrade_accepts_owned_old_version_and_rejects_unrelated_files
    Dir.mktmpdir("cronbar-wrapper-upgrade-") do |dir|
      wrapper = File.join(dir, "bin/solverforge-waybar-cronbar")
      FileUtils.mkdir_p(File.dirname(wrapper))
      env = { "SOLVERFORGE_PATH" => dir }
      File.write(wrapper, "#!/usr/bin/env bash\n# Managed by CronBar; installed by make install-solverforge.\necho old\n")
      out, err, status = run_tool(ROOT, "--install-solverforge", env: env)
      assert status.success?, out + err
      assert_equal File.read(File.join(ROOT, "bin/solverforge-waybar-cronbar")), File.read(wrapper)
      File.write(wrapper, "#!/bin/bash\necho unrelated\n")
      out, err, status = run_tool(ROOT, "--install-solverforge", env: env)
      refute status.success?, out + err
      assert_includes File.read(wrapper), "unrelated"
    end
  end

  def test_version_updaters_round_trip_and_fail_on_missing_surface
    script = <<~'JS'
      const fs = require('fs');
      const config = require('./.versionrc.js');
      for (const surface of config.bumpFiles) {
        const before = fs.readFileSync(surface.filename, 'utf8');
        const version = surface.updater.readVersion(before);
        const after = surface.updater.writeVersion(before, '9.8.7');
        if (surface.updater.readVersion(after) !== '9.8.7') throw new Error('version did not change');
        if (surface.updater.writeVersion(after, version) !== before) throw new Error('unrelated content changed');
        let threw = false;
        try { surface.updater.readVersion('no version'); } catch (_) { threw = true; }
        if (!threw) throw new Error('missing version accepted');
      }
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: ROOT)
    assert status.success?, out + err
  end

  def test_syntax_rejects_a_broken_shell_wrapper
    with_tool_tree do |dir|
      path = File.join(dir, "bin/solverforge-waybar-cronbar")
      File.write(path, "#!/usr/bin/env bash\nif then\n")
      out, err, status = run_tool(dir, "--syntax")
      refute status.success?, out + err
      assert_includes out + err, "solverforge-waybar-cronbar"
      File.write(path, "#!/usr/bin/env bash\nprintf 'ok\\n'\n")
      out, err, status = run_tool(dir, "--syntax")
      assert status.success?, out + err
    end
  end

  def test_syntax_checks_extensionless_cli_and_every_ruby_file
    with_tool_tree do |dir|
      File.write(File.join(dir, "lib/a.rb"), "puts 'valid'\n")
      File.write(File.join(dir, "lib/z.rb"), "def broken(\n")
      out, err, status = run_tool(dir, "--syntax")
      refute status.success?, out + err
      assert_includes out + err, "lib/z.rb"
      File.write(File.join(dir, "lib/z.rb"), "puts 'fixed'\n")
      File.write(File.join(dir, "bin/cronbar"), "def broken(\n")
      out, err, status = run_tool(dir, "--syntax")
      refute status.success?, out + err
      assert_includes out + err, "bin/cronbar"
      File.write(File.join(dir, "bin/cronbar"), "puts 'fixed'\n")
      out, err, status = run_tool(dir, "--syntax")
      assert status.success?, out + err
    end
  end
end
