require 'digest/sha1'
require 'fileutils'
require 'tempfile'
require 'tmpdir'

module SSHKit
  module Backend
    class OpenSSH < Abstract
      # One persistent `ssh -M` process per distinct connection (user, host,
      # port and ssh arguments). Commands attach to it with `-S <socket>`.
      class ControlMaster
        # Holds every master this process started, and the private directory
        # their sockets live in.
        class Registry
          def initialize
            @masters = {}
            @lock = Mutex.new
            @dir = nil
          end

          def for(host, connection_args, config)
            hostname = String(host.hostname)
            key = Digest::SHA1.hexdigest([hostname, *connection_args].join("\0"))[0, 16]
            @lock.synchronize do
              @masters[key] ||= ControlMaster.new(
                File.join(dir, key), hostname, connection_args, config
              )
            end
          end

          def close_all
            masters = @lock.synchronize { @masters.values.tap { @masters.clear } }
            masters.each(&:close)
            FileUtils.rm_rf(@dir) if @dir
            @dir = nil
          end

          private

          # Unix socket paths are limited to ~104 bytes on macOS, and macOS's
          # $TMPDIR is long, so always use /tmp. mktmpdir creates it 0700.
          def dir
            @dir ||= Dir.mktmpdir('sshkit-', File.directory?('/tmp') ? '/tmp' : nil)
          end
        end

        attr_reader :socket_path

        def initialize(socket_path, hostname, connection_args, config)
          @socket_path = socket_path
          @hostname = hostname
          @connection_args = connection_args
          @config = config
          @lock = Mutex.new
        end

        # Starts the master unless its socket is already there. Raises
        # ConnectionError with ssh's own message if it cannot connect.
        #
        # Checking for the socket file rather than running `-O check` saves a
        # process spawn per command. A master that exits removes its socket;
        # one killed outright leaves it behind, in which case ssh warns and
        # connects directly, so the command still runs.
        def ensure_started!
          @lock.synchronize do
            return if File.socket?(socket_path)

            start!
          end
        end

        def alive?
          control('check')
        end

        def close
          control('exit') if File.exist?(socket_path)
        end

        private

        def start!
          # -f backgrounds the master once it has authenticated. The daemon
          # keeps any pipe we give it open, so send its stderr to a file
          # rather than waiting on a pipe that never closes.
          Tempfile.create('sshkit-master') do |err|
            ok = system(*start_argv, in: File::NULL, out: File::NULL, err: err.path)
            return if ok

            message = File.read(err.path).strip
            raise ConnectionError, "ssh master connection to #{@hostname} failed: #{message}"
          end
        end

        def start_argv
          [
            @config.ssh_path, *@connection_args,
            '-M', '-N', '-f',
            '-S', socket_path,
            '-o', "ControlPersist=#{@config.idle_timeout.to_i}",
            '--', @hostname
          ]
        end

        def control(operation)
          system(
            @config.ssh_path, '-S', socket_path, '-O', operation, '--', @hostname,
            in: File::NULL, out: File::NULL, err: File::NULL
          ) || false
        end
      end
    end
  end
end
