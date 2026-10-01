# frozen_string_literal: true

require_relative "cronbar/core/config"
require_relative "cronbar/core/format"
require_relative "cronbar/core/process"
require_relative "cronbar/core/collectors"
require_relative "cronbar/runtime/state"
require_relative "cronbar/runtime/presenter"
require_relative "cronbar/runtime/runner"
require_relative "cronbar/runtime/daemon"
require_relative "cronbar/runtime/quickshell"
require_relative "cronbar/runtime/waybar"
require_relative "cronbar/runtime/omarchy"
require_relative "cronbar/cli"

module Cronbar
  VERSION = "0.1.0"
end
