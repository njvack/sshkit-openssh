require 'open3'
require 'sshkit'
require_relative 'openssh/configuration'
require_relative 'openssh/option_mapper'
require_relative 'openssh/control_master'

module SSHKit
  module Backend
    # Runs commands by spawning the system `ssh` binary. When multiplexing is
    # enabled (the default), all commands to a host share one ControlMaster
    # connection, which takes the place of Netssh's ConnectionPool.
    #
    #   require "sshkit/backends/openssh"
    #   SSHKit.config.backend = SSHKit::Backend::OpenSSH
    #
    # In Capistrano:
    #
    #   set :sshkit_backend, SSHKit::Backend::OpenSSH
    class OpenSSH < Abstract
      ConnectionError = Class.new(SSHKit::StandardError)

      # ssh exits 255 when it fails itself, and when the remote command is
      # killed by a signal or exits 255 on its own.
      SSH_FAILURE = 255
      READ_CHUNK = 16 * 1024

      class << self
        def configure
          yield config
        end

        def config
          @config ||= Configuration.new
        end

        def masters
          @masters ||= ControlMaster::Registry.new
        end
      end

      at_exit { OpenSSH.masters.close_all }

      # Full argv for running +command+ on this backend's host. Exposed for
      # testing and debugging.
      def ssh_argv(command)
        args = connection_args
        args += master ? ['-S', master.socket_path, '-o', 'ControlMaster=no'] : ['-o', 'ControlPath=none']
        args << (self.class.config.pty ? '-tt' : '-T')
        [self.class.config.ssh_path, *args, '--', String(host.hostname), command]
      end

      private

      def execute_command(cmd)
        output.log_command_start(cmd.with_redaction)
        cmd.started = true
        master&.ensure_started!
        status = spawn_and_stream(ssh_argv(cmd.to_command), cmd)
        if status == SSH_FAILURE && master && !master.alive?
          raise ConnectionError, "ssh connection to #{host} failed: #{cmd.full_stderr.strip}"
        end
        cmd.exit_status = status
        output.log_command_exit(cmd)
      end

      def spawn_and_stream(argv, cmd)
        Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
          # Without an interaction handler nothing will ever write to stdin, so
          # close it: commands that read stdin get EOF instead of hanging.
          stdin.close unless cmd.options[:interaction_handler]
          streams = { stdout => :stdout, stderr => :stderr }
          until streams.empty?
            IO.select(streams.keys).first.each do |io|
              data = read_chunk(io)
              if data.nil?
                streams.delete(io)
              elsif data != :wait
                dispatch(cmd, streams[io], stdin, data)
              end
            end
          end
          wait_thr.value.exitstatus || SSH_FAILURE
        end
      end

      def read_chunk(io)
        io.read_nonblock(READ_CHUNK).force_encoding(Encoding.default_external)
      rescue IO::WaitReadable
        :wait
      rescue EOFError
        nil
      end

      def dispatch(cmd, stream, stdin, data)
        if stream == :stdout
          cmd.on_stdout(stdin, data)
        else
          cmd.on_stderr(stdin, data)
        end
        output.log_command_data(cmd, stream, data)
      end

      def connection_args
        @connection_args ||= OptionMapper.new(host, self.class.config).to_args
      end

      def master
        return @master if defined?(@master)

        @master = if self.class.config.multiplex?
                    self.class.masters.for(
                      host, connection_args, self.class.config
                    )
                  end
      end
    end
  end
end
