require 'open3'
require 'shellwords'
require 'stringio'

module SSHKit
  module Backend
    class OpenSSH < Abstract
      # upload! and download! between paths with rsync (transfer_method
      # :rsync). rsync's -e runs our own ssh command line, so it shares the
      # ControlMaster and every ssh option. Destinations follow the same
      # scp-like rules as the cat/tar transfers.
      #
      # We quote remote paths for the remote shell ourselves, as rsync before
      # 3.2.4 (including the 2.6.9 that macOS ships) requires. Newer rsync
      # quotes them itself unless RSYNC_OLD_ARGS is set, so we always set it.
      module RsyncTransfers
        MINIMUM_VERSION = Gem::Version.new('2.6.9')
        PROGRESS_VERSION = Gem::Version.new('3.1.0') # --info=progress2

        @versions = {}
        @versions_lock = Mutex.new

        class << self
          # The local rsync's version, cached per binary path. Raises
          # TransferError if rsync is missing or older than MINIMUM_VERSION.
          def version(path)
            @versions_lock.synchronize { @versions[path] ||= detect_version(path) }
          end

          def reset_versions!
            @versions_lock.synchronize { @versions.clear }
          end

          private

          def detect_version(path)
            output, status = Open3.capture2e(path, '--version')
            # "rsync  version 3.2.7  protocol version 31", or openrsync's
            # "rsync version 2.6.9 compatible".
            found = output[/rsync\s+version\s+v?(\d+(?:\.\d+)+)/, 1] if status.success?
            raise TransferError, "could not read the version of #{path}: #{output.strip}" unless found

            version = Gem::Version.new(found)
            if version < MINIMUM_VERSION
              raise TransferError, "#{path} is version #{version}; transfer_method :rsync needs #{MINIMUM_VERSION} or newer"
            end

            version
          rescue SystemCallError => e
            raise TransferError, "transfer_method :rsync could not run #{path}: #{e.message}"
          end
        end

        private

        def rsync_upload(local, remote, options)
          local = File.expand_path(local)
          remote = trim_trailing_slashes(remote)
          if options[:recursive]
            info "Uploading #{local} to #{remote}"
            # Into an existing directory, rsync's "src dest" puts src inside
            # it; otherwise make dest and copy src's contents with "src/".
            into_existing = run_capture(
              "if [ -d #{escape(remote)} ]; then echo yes; else mkdir -p #{escape(remote)}; fi",
              "upload of #{local} to #{remote}"
            ).strip == 'yes'
            source = into_existing ? local : "#{local}/"
            run_rsync([source, rsync_remote("#{remote}/")], "upload of #{local} to #{remote}", recursive: true)
          elsif File.directory?(local)
            raise TransferError, "upload of #{local} failed: it is a directory; pass recursive: true"
          else
            progress = Transfers::Progress.new(self, 'Uploading', File.basename(local), 100, options)
            run_rsync([local, rsync_remote(remote)], "upload of #{local} to #{remote}", progress: progress)
          end
        end

        def rsync_download(remote, local, options)
          remote = trim_trailing_slashes(remote)
          local = File.expand_path(local)
          if options[:recursive]
            info "Downloading #{remote} to #{local}"
            into_existing = File.directory?(local)
            FileUtils.mkdir_p(local)
            source = into_existing ? remote : "#{remote}/"
            run_rsync([rsync_remote(source), "#{local}/"], "download of #{remote}", recursive: true)
          else
            local = File.join(local, File.basename(remote)) if File.directory?(local)
            progress = Transfers::Progress.new(self, 'Downloading', remote, 100, options)
            run_rsync([rsync_remote(remote), local], "download of #{remote}", progress: progress)
          end
        end

        def run_rsync(paths, description, recursive: false, progress: nil)
          config = self.class.config
          version = RsyncTransfers.version(config.rsync_path)
          argv = [config.rsync_path, *config.rsync_args, '-e', rsync_shell]
          argv << (recursive ? '--recursive' : '--no-recursive')
          # Older rsync just logs 100% when done.
          argv << '--info=progress2' if progress && version >= PROGRESS_VERSION
          argv.concat(paths)

          output = String.new
          errors = nil
          status = nil
          Open3.popen3({ 'RSYNC_OLD_ARGS' => '1' }, *argv) do |stdin, stdout, stderr, wait_thr|
            stdin.close
            err_reader = Thread.new { stderr.read }
            read_rsync_output(stdout, output, progress)
            errors = err_reader.value
            status = wait_thr.value.exitstatus
          end
          # --no-recursive skips a directory source with only this message.
          skipped = output[/^skipping directory .*$/]
          if status&.zero? && !skipped
            progress&.finish
            return
          end

          detail = [errors, skipped].compact.join("\n").strip
          raise TransferError, "rsync #{description} failed (exit #{status.inspect}): #{detail}"
        end

        # Reads rsync's stdout into +output+, feeding --info=progress2
        # percentages (on \r-separated lines) to +progress+.
        def read_rsync_output(stdout, output, progress)
          done = 0
          tail = String.new
          while (chunk = stdout.readpartial(4096))
            output << chunk
            next unless progress

            # Keep a little of the previous chunk in case a number is split.
            tail = (tail + chunk)[-64..] || (tail + chunk)
            percent = tail.scan(/(\d{1,3})%/).last&.first.to_i
            next unless percent > done

            progress.advance(percent - done)
            done = percent
          end
        rescue EOFError
          nil
        end

        def run_capture(command, description)
          sink = StringIO.new
          run_transfer(command, description, sink: sink)
          sink.string
        end

        # Our ssh command line as one -e string. rsync splits it on spaces
        # and understands single quotes.
        def rsync_shell
          ssh_prefix(pty: false).map { |word| rsync_shell_word(word) }.join(' ')
        end

        def rsync_shell_word(word)
          return word if word.match?(%r{\A[\w@%+=:,./-]+\z})

          "'#{word.gsub("'") { %('"'"') }}'"
        end

        # host:path for rsync, with path quoted for the remote shell. IPv6
        # addresses need brackets so rsync finds the right colon.
        def rsync_remote(path)
          hostname = String(host.hostname)
          hostname = "[#{hostname}]" if hostname.include?(':')
          "#{hostname}:#{escape(path)}"
        end

        def trim_trailing_slashes(path)
          path.length > 1 ? path.sub(%r{(?<=.)/+\z}, '') : path
        end
      end
    end
  end
end
