require 'open3'
require 'sshkit'
require_relative 'openssh/configuration'
require_relative 'openssh/option_mapper'
require_relative 'openssh/control_master'
require_relative 'openssh/transfers'
require_relative 'openssh/rsync'

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
      TransferError = Class.new(SSHKit::StandardError)

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

      include Transfers
      include RsyncTransfers

      # Raised when the backend is used on native Windows. Requiring the gem
      # there is harmless, so a team can pick the backend per platform.
      UnsupportedPlatformError = Class.new(SSHKit::StandardError)

      def initialize(*)
        if Gem.win_platform?
          raise UnsupportedPlatformError,
                'SSHKit::Backend::OpenSSH does not support native Windows (OpenSSH for Windows has no ' \
                'ControlMaster support). Run Capistrano from WSL, or use SSHKit::Backend::Netssh.'
        end
        super
      end

      # Full argv for running +command+ on this backend's host. Exposed for
      # testing and debugging. Transfers pass pty: false, since a pty would
      # mangle binary data.
      def ssh_argv(command, pty: self.class.config.pty)
        [*ssh_prefix(pty: pty), String(host.hostname), command]
      end

      # ssh and its options, ending with `--`; the destination and command
      # come next. rsync's `-e` uses this too.
      def ssh_prefix(pty: false)
        args = connection_args
        args += master ? ['-S', master.socket_path, '-o', 'ControlMaster=no'] : ['-o', 'ControlPath=none']
        args << (pty ? '-tt' : '-T')
        [self.class.config.ssh_path, *args, '--']
      end

      # Same as Abstract#within, but with a directory check that survives
      # Command#sanitize_command. Core's check is a multi-line heredoc, and
      # sanitize_command splits commands on newlines and strips each line,
      # which mangles directory names containing a newline or ending in a
      # space. This check is one line, keeps the path away from the line's
      # end, and spells newlines with a shell variable.
      def within(directory, &_block)
        (@pwd ||= []).push directory.to_s
        execute directory_check(pwd_path), verbosity: Logger::DEBUG
        yield
      ensure
        @pwd.pop
      end

      private

      def directory_check(path)
        word = single_line_shell_word(path)
        prelude = path.include?("\n") ? "nl=$(printf '\\nx'); nl=${nl%x}; " : ''
        "#{prelude}if test ! -d #{word}; then " \
          "printf \"Directory does not exist '%s'\\n\" #{word} 1>&2; false; fi"
      end

      # A shell word for +path+ with no literal newline in it. A leading
      # ~ or ~user stays unquoted so the remote shell expands it, as with
      # Command.shellescape_except_tilde.
      def single_line_shell_word(path)
        prefix = path[/\A~[\w.-]*(?=\/|\z)/] || ''
        rest = path[prefix.length..-1]
        quoted = rest.split("\n", -1).map { |part| part.empty? ? '' : Shellwords.escape(part) }.join('"$nl"')
        word = prefix + quoted
        word.empty? ? "''" : word
      end

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
