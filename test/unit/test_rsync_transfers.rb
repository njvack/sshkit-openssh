require 'helper'
require_relative 'test_transfers'

module SSHKit
  module Backend
    # Reruns every TestTransfers case with transfer_method :rsync, against
    # the local rsync, plus rsync-specific cases.
    class TestRsyncTransfers < TestTransfers
      def setup
        skip 'rsync is not installed' unless system('rsync --version >/dev/null 2>&1')
        super
        OpenSSH.configure { |c| c.transfer_method = :rsync }
        OpenSSH::RsyncTransfers.reset_versions!
        @bin = Dir.mktmpdir('bin')
      end

      def teardown
        super
        FileUtils.rm_rf(@bin) if @bin
        OpenSSH::RsyncTransfers.reset_versions!
      end

      def script(name, body)
        path = File.join(@bin, name)
        File.write(path, "#!/bin/sh\n#{body}\n")
        File.chmod(0o755, path)
        path
      end

      # An rsync that claims to be +version+, logs its arguments, and runs
      # the real rsync (or exits 0 without it, with run: false, since the
      # real one may not take the options the claimed version gets).
      def fake_rsync(version_line, run: true)
        real = `sh -c 'command -v rsync'`.strip
        log = File.join(@bin, 'args')
        path = script('rsync', <<~SH)
          if [ "$1" = --version ]; then echo '#{version_line}'; exit 0; fi
          printf '%s\\n' "$@" > '#{log}'
          #{run ? %(exec '#{real}' "$@") : 'exit 0'}
        SH
        OpenSSH.config.rsync_path = path
        log
      end

      def test_uses_rsync_through_our_ssh_command
        log = fake_rsync('rsync  version 3.2.7  protocol version 31', run: false)
        src = File.join(@local, 'f')
        write(src, 'x')
        on_backend { |b| b.upload! src, @remote }
        args = File.read(log).lines(chomp: true)
        assert_equal '-a', args.first
        shell = args[args.index('-e') + 1]
        assert shell.start_with?(FAKE_SSH), shell
        assert shell.end_with?(' -T --'), shell
        assert_includes args, '--no-recursive'
        assert_includes args, '--info=progress2'
      end

      def test_shares_the_control_master
        OpenSSH.config.idle_timeout = 30
        backend = OpenSSH.new(Host.new('example.com'))
        shell = backend.send(:rsync_shell)
        assert_match(/ -S \S+ -o ControlMaster=no -T --\z/, shell)
      end

      def test_old_rsync_skips_progress_but_still_logs_completion
        log = fake_rsync('rsync  version 2.6.9  protocol version 29')
        src = File.join(@local, 'big')
        write(src, 'x' * 200_000)
        on_backend { |b| b.upload! src, File.join(@remote, 'big') }
        refute_includes File.read(log), '--info'
        assert_match(/Uploading big 100%/, @output)
      end

      def test_openrsync_version_line
        fake_rsync("openrsync: protocol version 29\nrsync version 2.6.9 compatible")
        assert_equal Gem::Version.new('2.6.9'), OpenSSH::RsyncTransfers.version(OpenSSH.config.rsync_path)
      end

      def test_too_old_rsync_raises
        fake_rsync('rsync  version 2.6.8  protocol version 29')
        src = File.join(@local, 'f')
        write(src, 'x')
        err = assert_raises(OpenSSH::TransferError) { on_backend { |b| b.upload! src, @remote } }
        assert_match(/2\.6\.8.*2\.6\.9 or newer/, err.message)
      end

      def test_missing_local_rsync_raises
        OpenSSH.config.rsync_path = File.join(@bin, 'no-rsync-here')
        src = File.join(@local, 'f')
        write(src, 'x')
        err = assert_raises(OpenSSH::TransferError) { on_backend { |b| b.upload! src, @remote } }
        assert_match(/could not run/, err.message)
      end

      def test_missing_remote_rsync_raises
        OpenSSH.config.ssh_path = script('ssh', <<~'SH')
          while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
          shift 2
          exec /bin/sh -c "PATH=/nonexistent; $*"
        SH
        src = File.join(@local, 'f')
        write(src, 'x')
        err = assert_raises(OpenSSH::TransferError) { on_backend { |b| b.upload! src, @remote } }
        assert_match(/rsync upload .* failed/, err.message)
        assert_match(/not found/, err.message)
      end

      def test_ssh_path_with_spaces_and_quotes
        dir = File.join(@bin, "it's a dir")
        FileUtils.mkdir_p(dir)
        OpenSSH.config.ssh_path = File.join(dir, 'ssh')
        FileUtils.cp(FAKE_SSH, OpenSSH.config.ssh_path)
        src = File.join(@local, 'f')
        write(src, 'x')
        on_backend { |b| b.upload! src, @remote }
        assert_equal 'x', File.read(File.join(@remote, 'f'))
      end

      def test_non_recursive_download_of_directory_raises
        FileUtils.mkdir_p(File.join(@remote, 'dir'))
        err = assert_raises(OpenSSH::TransferError) do
          on_backend { |b| b.download! File.join(@remote, 'dir'), @local }
        end
        assert_match(/skipping directory/, err.message)
      end

      def test_non_recursive_upload_of_directory_raises
        FileUtils.mkdir_p(File.join(@local, 'dir'))
        err = assert_raises(OpenSSH::TransferError) { on_backend { |b| b.upload! File.join(@local, 'dir'), @remote } }
        assert_match(/recursive: true/, err.message)
      end

      def test_default_args_preserve_mtime
        src = File.join(@local, 'old')
        write(src, 'x')
        File.utime(Time.at(1_000_000_000), Time.at(1_000_000_000), src)
        on_backend { |b| b.upload! src, @remote }
        assert_equal 1_000_000_000, File.mtime(File.join(@remote, 'old')).to_i
      end

      def test_rsync_args_are_configurable
        OpenSSH.config.rsync_args = ['-a', '--delete']
        write(File.join(@local, 'tree', 'keep'), 'k')
        write(File.join(@remote, 'tree', 'stale'), 's')
        on_backend { |b| b.upload! File.join(@local, 'tree'), @remote, recursive: true }
        assert File.exist?(File.join(@remote, 'tree', 'keep'))
        refute File.exist?(File.join(@remote, 'tree', 'stale'))
      end

      def test_tilde_remote_path
        Dir.mktmpdir('sshkit-rsync-home', Dir.home) do |dir|
          name = File.basename(dir)
          src = File.join(@local, 'f')
          write(src, 'home')
          on_backend { |b| b.upload! src, "~/#{name}/f" }
          assert_equal 'home', File.read(File.join(dir, 'f'))
          assert_equal 'home', on_backend { |b| b.download! "~/#{name}/f" }
        end
      end
    end

    class TestTransferMethodConfig < UnitTest
      def test_rejects_unknown_methods
        config = OpenSSH::Configuration.new
        assert_equal :stream, config.transfer_method
        config.transfer_method = 'rsync'
        assert_equal :rsync, config.transfer_method
        assert_raises(ArgumentError) { config.transfer_method = :scp }
      end
    end
  end
end
