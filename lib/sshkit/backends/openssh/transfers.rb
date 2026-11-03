require 'fileutils'
require 'open3'
require 'stringio'

module SSHKit
  module Backend
    class OpenSSH < Abstract
      # upload! and download! over the same ssh connection as commands:
      # single files and IO objects stream through `cat`, directories through
      # `tar`. This avoids scp/sftp version differences (OpenSSH 9 switched
      # scp to the SFTP protocol) and needs only cat, tar and mkdir remotely.
      #
      # Destination rules follow scp: if the destination is an existing
      # directory, the source lands inside it under its own name; otherwise
      # the destination path becomes the copy.
      module Transfers
        CHUNK = 64 * 1024

        def upload!(local, remote, options = {})
          remote = absolute_remote(remote)
          master&.ensure_started!
          if local.respond_to?(:read)
            upload_io(local, remote, nil, options)
          elsif options[:recursive] && File.directory?(local)
            upload_directory(local.to_s, remote)
          else
            upload_file(local.to_s, remote, options)
          end
          true
        end

        def download!(remote, local = nil, options = {})
          remote = absolute_remote(remote)
          master&.ensure_started!
          if local.nil?
            sink = StringIO.new(String.new(encoding: Encoding::BINARY))
            download_to(remote, sink, remote)
            sink.string
          elsif local.respond_to?(:write)
            download_to(remote, local, remote)
            true
          elsif options[:recursive]
            download_directory(remote, local.to_s)
            true
          else
            local = File.join(local, File.basename(remote)) if File.directory?(local)
            File.open(local, 'wb') { |file| download_to(remote, file, remote) }
            true
          end
        end

        private

        def absolute_remote(remote)
          remote = remote.to_s
          remote.start_with?('/', '~') || pwd_path.nil? ? remote : File.join(pwd_path, remote)
        end

        def upload_file(local, remote, options)
          File.open(local, 'rb') do |file|
            upload_io(file, remote, File.basename(local), options, File.size(local))
          end
        end

        def upload_io(io, remote, name, options, size = nil)
          target = escape(remote)
          command = if name
                      "if [ -d #{target} ]; then cat > #{escape(File.join(remote, name))}; else cat > #{target}; fi"
                    else
                      "cat > #{target}"
                    end
          size ||= io.size if io.respond_to?(:size)
          progress = Progress.new(self, 'Uploading', name || remote, size, options)
          run_transfer(command, "upload to #{remote}", input: io, progress: progress)
        end

        def upload_directory(local, remote)
          local = File.expand_path(local)
          target = escape(remote)
          command = "if [ -d #{target} ]; then tar -C #{target} -xf -; " \
                    "else mkdir -p #{target} && tar -C #{target} --strip-components=1 -xf -; fi"
          info "Uploading #{local} to #{remote}"
          # `--` keeps a name like "-x" from being read as an option.
          IO.popen(['tar', '-C', File.dirname(local), '-cf', '-', '--', File.basename(local)], 'rb') do |tar|
            run_transfer(command, "upload of #{local} to #{remote}", input: tar)
          end
          raise TransferError, "local tar of #{local} failed" unless $?.success?
        end

        def download_to(remote, sink, name, options = {})
          progress = Progress.new(self, 'Downloading', name, nil, options)
          run_transfer("cat #{escape(remote)}", "download of #{remote}", sink: sink, progress: progress)
        end

        def download_directory(remote, local)
          local = File.expand_path(local)
          into_existing = File.directory?(local)
          FileUtils.mkdir_p(local)
          tar = ['tar', '-C', local, '-xf', '-']
          tar.insert(3, '--strip-components=1') unless into_existing
          info "Downloading #{remote} to #{local}"
          command = "tar -C #{escape(File.dirname(remote))} -cf - -- #{escape(File.basename(remote))}"
          IO.popen(tar, 'wb') do |untar|
            run_transfer(command, "download of #{remote}", sink: untar)
          end
          raise TransferError, "local untar into #{local} failed" unless $?.success?
        end

        # Runs +command+ remotely, feeding +input+ to its stdin and copying
        # its stdout to +sink+. Raises TransferError on a non-zero exit.
        def run_transfer(command, description, input: nil, sink: nil, progress: nil)
          Open3.popen3(*ssh_argv(command, pty: false)) do |stdin, stdout, stderr, wait_thr|
            [stdin, stdout, stderr].each(&:binmode)
            writer = Thread.new do
              copy_stream(input, stdin, progress) if input
            rescue Errno::EPIPE
              nil # remote side failed early; its exit status says why
            ensure
              stdin.close
            end
            reader = Thread.new { sink ? copy_stream(stdout, sink, progress) : stdout.read }
            errors = stderr.read
            writer.join
            reader.join
            status = wait_thr.value.exitstatus
            progress&.finish if status&.zero?
            return if status&.zero?

            raise TransferError, "#{description} failed (exit #{status.inspect}): #{errors.strip}"
          end
        end

        def copy_stream(source, destination, progress)
          while (chunk = source.read(CHUNK))
            destination.write(chunk)
            progress&.advance(chunk.bytesize)
          end
        end

        def escape(path)
          Command.shellescape_except_tilde(path)
        end

        # Logs "Uploading name 40%"-style messages at each log_percent step,
        # like Netssh's transfer summarizer. Without a known size it logs
        # only the total at the end.
        class Progress
          def initialize(backend, action, name, total, options)
            @backend = backend
            @action = action
            @name = name
            @total = total
            @step = options[:log_percent].to_i.positive? ? options[:log_percent].to_i : 10
            @level = (options[:verbosity] || :info).to_s.downcase
            @done = 0
            @last_logged = 0
          end

          def advance(bytes)
            @done += bytes
            return unless @total&.positive?

            percent = (@done * 100 / @total / @step) * @step
            return unless percent > @last_logged

            @last_logged = percent
            log("#{@action} #{@name} #{percent}%")
          end

          def finish
            if @total.nil?
              log("#{@action} #{@name} (#{@done} bytes)")
            elsif @last_logged < 100
              log("#{@action} #{@name} 100%")
            end
          end

          private

          def log(message)
            @backend.public_send(@level, message)
          end
        end
      end
    end
  end
end
