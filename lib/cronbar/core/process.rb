# frozen_string_literal: true

require "open3"
require "timeout"

module Cronbar
  module Core
    module Process
      Result = Struct.new(:status, :stdout, :stderr, :timed_out, keyword_init: true) do
        def success?
          !timed_out && status&.success?
        end

        def exit_code
          return nil if timed_out || status.nil?

          status.exitstatus
        end
      end

      module_function

      def run_command(command, args = [], timeout: 10, env: {})
        stdout = +""
        stderr = +""
        status = nil

        Timeout.timeout(timeout) do
          stdout, stderr, status = Open3.capture3(env, command, *args.map(&:to_s))
        end

        Result.new(status: status, stdout: stdout, stderr: stderr, timed_out: false)
      rescue Timeout::Error
        Result.new(status: nil, stdout: stdout, stderr: "command timed out", timed_out: true)
      rescue Errno::ENOENT, Errno::EACCES => e
        Result.new(status: nil, stdout: "", stderr: e.message, timed_out: false)
      end
    end
  end
end
