require 'helper'
require 'tmpdir'

module SSHKit
  module Backend
    # Uses the fake ssh, which runs the "remote" command locally, so these
    # exercise the real cat/tar pipelines against a temp directory.
    class TestTransfers < UnitTest
      FAKE_SSH = File.expand_path('../support/fake_ssh', __dir__)

      def setup
        super
        OpenSSH.instance_variable_set(:@config, nil)
        OpenSSH.configure do |c|
          c.idle_timeout = 0
          c.ssh_path = FAKE_SSH
        end
        @output = String.new
        SSHKit.config.output_verbosity = :debug
        SSHKit.config.output = SSHKit::Formatter::SimpleText.new(@output)
        @local = Dir.mktmpdir('local')
        @remote = Dir.mktmpdir('remote "quoted" dir')
      end

      def teardown
        FileUtils.rm_rf([@local, @remote])
      end

      def on_backend
        yield OpenSSH.new(Host.new('example.com'))
      end

      def write(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
      end

      def test_upload_stringio
        dest = File.join(@remote, 'git-ssh.sh')
        on_backend { |b| b.upload! StringIO.new("#!/bin/sh\necho hi\n"), dest }
        assert_equal "#!/bin/sh\necho hi\n", File.read(dest)
      end

      def test_upload_file_to_path_and_into_directory
        src = File.join(@local, 'app.conf')
        write(src, 'conf')
        on_backend { |b| b.upload! src, File.join(@remote, 'renamed.conf') }
        on_backend { |b| b.upload! src, @remote }
        assert_equal 'conf', File.read(File.join(@remote, 'renamed.conf'))
        assert_equal 'conf', File.read(File.join(@remote, 'app.conf'))
      end

      def test_upload_binary_file_is_byte_identical
        src = File.join(@local, 'blob.bin')
        bytes = Random.new(1).bytes(300_000)
        write(src, bytes)
        on_backend { |b| b.upload! src, File.join(@remote, 'blob.bin') }
        assert_equal bytes, File.binread(File.join(@remote, 'blob.bin'))
      end

      def test_upload_relative_path_uses_within
        on_backend { |b| b.within(@remote) { b.upload! StringIO.new('x'), 'rel.txt' } }
        assert_equal 'x', File.read(File.join(@remote, 'rel.txt'))
      end

      def test_upload_directory_recursive_into_new_and_existing_destination
        write(File.join(@local, 'assets', 'a.txt'), 'a')
        write(File.join(@local, 'assets', 'sub', 'b.txt'), 'b')
        src = File.join(@local, 'assets')
        fresh = File.join(@remote, 'fresh')
        on_backend { |b| b.upload! src, fresh, recursive: true }
        assert_equal 'b', File.read(File.join(fresh, 'sub', 'b.txt'))
        on_backend { |b| b.upload! src, @remote, recursive: true }
        assert_equal 'a', File.read(File.join(@remote, 'assets', 'a.txt'))
      end

      def test_upload_failure_raises
        src = File.join(@local, 'f')
        write(src, 'x')
        err = assert_raises(OpenSSH::TransferError) do
          on_backend { |b| b.upload! src, '/nonexistent-dir/for/sure/f' }
        end
        assert_match(/nonexistent-dir/, err.message)
      end

      def test_upload_logs_progress
        src = File.join(@local, 'big')
        write(src, 'x' * 200_000)
        on_backend { |b| b.upload! src, File.join(@remote, 'big') }
        assert_match(/Uploading big 100%/, @output)
      end

      def test_download_returns_string_without_local
        write(File.join(@remote, 'log.txt'), "line\n")
        path = File.join(@remote, 'log.txt')
        assert_equal "line\n", on_backend { |b| b.download! path }
      end

      def test_download_to_io_and_path
        write(File.join(@remote, 'data'), 'payload')
        path = File.join(@remote, 'data')
        io = StringIO.new
        on_backend { |b| b.download! path, io }
        assert_equal 'payload', io.string
        on_backend { |b| b.download! path, File.join(@local, 'copy') }
        on_backend { |b| b.download! path, @local }
        assert_equal 'payload', File.read(File.join(@local, 'copy'))
        assert_equal 'payload', File.read(File.join(@local, 'data'))
      end

      def test_download_directory_recursive
        write(File.join(@remote, 'logs', 'a.log'), 'a')
        write(File.join(@remote, 'logs', 'old', 'b.log'), 'b')
        src = File.join(@remote, 'logs')
        on_backend { |b| b.download! src, File.join(@local, 'fresh'), recursive: true }
        assert_equal 'b', File.read(File.join(@local, 'fresh', 'old', 'b.log'))
        on_backend { |b| b.download! src, @local, recursive: true }
        assert_equal 'a', File.read(File.join(@local, 'logs', 'a.log'))
      end

      def test_download_missing_file_raises
        missing = File.join(@remote, 'missing')
        assert_raises(OpenSSH::TransferError) { on_backend { |b| b.download! missing } }
      end

      ODD_NAMES = [
        'with space', "single'quote", 'double"quote', '$HOME', 'back`tick`', '-leading-dash',
        'semi;colon', 'glob*?[x]', 'ünïcödé', "new\nline", 'trailing space ', '~tilde'
      ].freeze

      def test_odd_filenames_round_trip
        ODD_NAMES.each do |name|
          src = File.join(@local, name)
          write(src, "content of #{name}")
          on_backend { |b| b.upload! src, @remote }
          assert_equal "content of #{name}".b, File.binread(File.join(@remote, name)), "upload of #{name.inspect}"
          back = File.join(@local, 'back')
          FileUtils.mkdir_p(back)
          on_backend { |b| b.download! File.join(@remote, name), back }
          assert_equal "content of #{name}".b, File.binread(File.join(back, name)), "download of #{name.inspect}"
          assert_equal "content of #{name}".b, on_backend { |b| b.download! File.join(@remote, name) }.b
        end
      end

      def test_odd_directory_names_round_trip_recursively
        ODD_NAMES.each do |name|
          src = File.join(@local, 'up', name)
          write(File.join(src, 'inner file'), name)
          on_backend { |b| b.upload! src, @remote, recursive: true }
          assert_equal name.b, File.binread(File.join(@remote, name, 'inner file')), "recursive upload of #{name.inspect}"
          on_backend { |b| b.download! File.join(@remote, name), @local, recursive: true }
          assert_equal name.b, File.binread(File.join(@local, name, 'inner file')), "recursive download of #{name.inspect}"
        end
      end

      # SSHKit core's Command#sanitize_command splits commands on newlines and
      # strips each line, so within() breaks on directory names containing a
      # newline or ending in a space, on every backend.
      def test_odd_names_through_within
        (ODD_NAMES - ["new\nline", 'trailing space ']).each do |name|
          dir = File.join(@remote, "dir #{name}")
          FileUtils.mkdir_p(dir)
          on_backend { |b| b.within(dir) { b.upload! StringIO.new(name), 'f' } }
          assert_equal name.b, File.binread(File.join(dir, 'f')), "within #{name.inspect}"
        end
      end

      def test_transfers_never_use_a_pty
        OpenSSH.config.pty = true
        argv = on_backend { |b| b.ssh_argv('cat', pty: false) }
        assert_includes argv, '-T'
        refute_includes argv, '-tt'
      end
    end
  end
end
