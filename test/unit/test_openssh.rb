require 'helper'
require 'sshkit/openssh'

module SSHKit
  module Backend
    class TestOpenSSH < UnitTest
      FAKE_SSH = File.expand_path('../support/fake_ssh', __dir__)

      def setup
        super
        OpenSSH.instance_variable_set(:@config, nil)
        @output = String.new
        SSHKit.config.output_verbosity = :debug
        SSHKit.config.output = SSHKit::Formatter::SimpleText.new(@output)
      end

      def host
        @host ||= Host.new('deployer@example.com:2222')
      end

      def backend(&block)
        OpenSSH.new(host, &block)
      end

      def without_multiplexing
        OpenSSH.configure do |c|
          c.idle_timeout = 0
          c.ssh_path = FAKE_SSH
        end
      end

      # Configuration

      def test_capistrano_config_accessors
        OpenSSH.configure do |c|
          c.pty = true
          c.connection_timeout = 5
          c.ssh_options = (c.ssh_options || {}).merge(keys_only: true)
        end
        assert_equal true, OpenSSH.config.pty
        assert_equal 5, OpenSSH.config.connection_timeout
        assert_equal({ keys_only: true }, OpenSSH.config.ssh_options)
      end

      def test_multiplex_disabled_by_zero_false_or_nil
        config = OpenSSH::Configuration.new
        assert config.multiplex?
        [0, false, nil].each do |value|
          config.idle_timeout = value
          refute config.multiplex?, "idle_timeout=#{value.inspect} should disable multiplexing"
        end
      end

      # Option mapping

      def mapped(host_obj = host)
        OpenSSH::OptionMapper.new(host_obj, OpenSSH.config).to_args
      end

      def test_maps_user_port_and_default_agent_forwarding
        args = mapped
        assert_equal %w[-l deployer -p 2222], args[0, 4]
        assert_includes args.each_slice(2).to_a, ['-o', 'ForwardAgent=yes']
        assert_includes args.each_slice(2).to_a, ['-o', 'LogLevel=ERROR']
      end

      def test_config_ssh_options_override_host_defaults
        OpenSSH.config.ssh_options = { forward_agent: false, user: 'other' }
        args = mapped
        assert_includes args.each_slice(2).to_a, ['-o', 'ForwardAgent=no']
        assert_equal %w[-l other], args[0, 2]
      end

      def test_host_ssh_options_override_config
        OpenSSH.config.ssh_options = { forward_agent: false }
        h = Host.new(hostname: 'example.com', ssh_options: { forward_agent: true })
        assert_includes mapped(h).each_slice(2).to_a, ['-o', 'ForwardAgent=yes']
      end

      def test_maps_keys_keys_only_and_timeout
        OpenSSH.config.connection_timeout = 7
        h = Host.new(hostname: 'example.com', keys: ['/k/one', '/k/two'], ssh_options: { keys_only: true })
        args = mapped(h)
        assert_equal %w[-i /k/one -i /k/two], args.each_slice(2).select { |f, _| f == '-i' }.flatten
        assert_includes args.each_slice(2).to_a, ['-o', 'IdentitiesOnly=yes']
        assert_includes args.each_slice(2).to_a, ['-o', 'ConnectTimeout=7']
      end

      def test_ssh_options_timeout_wins_over_connection_timeout
        OpenSSH.config.connection_timeout = 7
        OpenSSH.config.ssh_options = { timeout: 3 }
        assert_includes mapped.each_slice(2).to_a, ['-o', 'ConnectTimeout=3']
      end

      def test_raw_ssh_args_are_appended_and_suppress_default_log_level
        OpenSSH.config.ssh_args = ['-v']
        h = Host.new(hostname: 'example.com', ssh_options: { openssh_args: ['-o', 'Compression=yes'] })
        args = mapped(h)
        assert_equal ['-v', '-o', 'Compression=yes'], args.last(3)
        refute_includes args, 'LogLevel=ERROR'
      end

      # Command line

      def test_ssh_argv_without_multiplexing
        OpenSSH.config.idle_timeout = 0
        argv = backend.ssh_argv('uptime')
        assert_equal 'ssh', argv.first
        assert_equal ['-o', 'ControlPath=none', '-T', '--', 'example.com', 'uptime'], argv.last(6)
      end

      def test_ssh_argv_with_multiplexing_uses_control_socket
        argv = backend.ssh_argv('uptime')
        socket = argv[argv.index('-S') + 1]
        assert_match %r{\A/tmp/sshkit-[^/]+/\h{16}\z}, socket
        assert_includes argv, 'ControlMaster=no'
        assert_equal ['-T', '--', 'example.com', 'uptime'], argv.last(4)
      ensure
        OpenSSH.masters.close_all
      end

      def test_hosts_with_different_options_get_different_masters
        a = Host.new(hostname: 'example.com', ssh_options: { forward_agent: true })
        b = Host.new(hostname: 'example.com', ssh_options: { forward_agent: false })
        socket = ->(h) { argv = OpenSSH.new(h).ssh_argv('x'); argv[argv.index('-S') + 1] }
        refute_equal socket.call(a), socket.call(b)
        assert_equal socket.call(a), socket.call(Host.new(hostname: 'example.com', ssh_options: { forward_agent: true }))
      ensure
        OpenSSH.masters.close_all
      end

      def test_refuses_native_windows
        Gem.singleton_class.alias_method(:__real_win_platform?, :win_platform?)
        Gem.define_singleton_method(:win_platform?) { true }
        assert_raises(OpenSSH::UnsupportedPlatformError) { OpenSSH.new(host) }
      ensure
        Gem.singleton_class.alias_method(:win_platform?, :__real_win_platform?)
      end

      def test_pty_uses_tt
        OpenSSH.config.idle_timeout = 0
        OpenSSH.config.pty = true
        assert_includes backend.ssh_argv('x'), '-tt'
      end

      # Execution (through a fake ssh that runs the command locally)

      def test_execute_capture_and_test
        without_multiplexing
        captured = nil
        results = []
        backend do
          results << execute(:echo, 'hi')
          captured = capture(:echo, 'hello world')
          results << test('false')
          results << test('true')
        end.run
        assert_equal 'hello world', captured
        assert_equal [true, false, true], results
      end

      def test_non_zero_exit_raises
        without_multiplexing
        err = assert_raises(SSHKit::Command::Failed) do
          backend { execute 'echo oops 1>&2; exit 3' }.run
        end
        assert_match(/exit status: 3/, err.message)
        assert_match(/oops/, err.message)
      end

      def test_streams_stdout_and_stderr_separately
        without_multiplexing
        backend { execute 'echo out; echo err 1>&2' }.run
        assert_match(/\tout$/, @output)
        assert_match(/\terr$/, @output)
      end

      def test_stdin_is_closed_without_interaction_handler
        without_multiplexing
        captured = nil
        backend { captured = capture('cat; echo done') }.run
        assert_equal 'done', captured
      end

      def test_interaction_handler_receives_partial_lines_and_can_reply
        without_multiplexing
        captured = nil
        backend do
          captured = capture(
            'printf "Password: "; read answer; echo "got $answer"',
            interaction_handler: { 'Password: ' => "secret\n" }
          )
        end.run
        assert_equal 'Password: got secret', captured
      end

      def test_within_and_with_are_applied
        without_multiplexing
        captured = []
        backend do
          within('/') { with(foo: 'bar') { captured << capture(:pwd) << capture(:printenv, 'FOO') } }
        end.run
        assert_equal ['/', 'bar'], captured
      end
    end
  end
end
