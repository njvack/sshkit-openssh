require 'helper'
require 'sshkit/openssh'

module SSHKit
  module Backend
    # Runs against a real sshd. Set SSHKIT_OPENSSH_TEST_HOST (for example
    # deployer@127.0.0.1:2122) and optionally SSHKIT_OPENSSH_TEST_KEY. The
    # user needs passwordless sudo, like the `deployer` user in .docker.
    class TestOpenSSH < Minitest::Test
      HOST = ENV['SSHKIT_OPENSSH_TEST_HOST']
      KEY = ENV['SSHKIT_OPENSSH_TEST_KEY']

      def setup
        skip 'set SSHKIT_OPENSSH_TEST_HOST to run OpenSSH functional tests' unless HOST
        SSHKit.reset_configuration!
        OpenSSH.instance_variable_set(:@config, nil)
        OpenSSH.configure do |c|
          c.ssh_args = %w[-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes]
          c.ssh_options = KEY ? { keys: [KEY], keys_only: true } : {}
        end
        @output = String.new
        SSHKit.config.output_verbosity = :debug
        SSHKit.config.output = SSHKit::Formatter::SimpleText.new(@output)
      end

      def teardown
        OpenSSH.masters.close_all
      end

      def a_host
        Host.new(HOST)
      end

      def run_on(host = a_host, &block)
        OpenSSH.new(host, &block).run
      end

      def socket_for(host = a_host)
        argv = OpenSSH.new(host).ssh_argv('true')
        argv[argv.index('-S') + 1]
      end

      def test_dsl_round_trip
        results = []
        run_on do
          results << capture(:echo, 'hello')
          results << test('[ -d /tmp ]')
          within('/tmp') { as(:root) { results << capture(:pwd) << capture(:whoami) } }
          with(rails_env: 'production') { results << capture(:printenv, 'RAILS_ENV') }
        end
        assert_equal ['hello', true, '/tmp', 'root', 'production'], results
      end

      def test_commands_share_one_master
        run_on { capture(:true) }
        socket = socket_for
        assert File.socket?(socket), 'master socket should exist after first command'
        started = Time.now
        run_on { 10.times { capture(:true) } }
        assert_operator Time.now - started, :<, 2, 'ten multiplexed commands should be fast'
      end

      def test_master_is_restarted_if_it_exits
        run_on { capture(:true) }
        socket = socket_for
        system('ssh', '-S', socket, '-O', 'exit', 'x', err: File::NULL)
        refute File.exist?(socket)
        assert_equal 'again', run_on_capture { capture(:echo, 'again') }
        assert File.socket?(socket)
      end

      def test_without_multiplexing
        OpenSSH.config.idle_timeout = 0
        assert_equal 'direct', run_on_capture { capture(:echo, 'direct') }
      end

      def test_remote_exit_255_is_not_a_connection_error
        assert_raises(SSHKit::Command::Failed) { run_on { execute 'exit 255' } }
      end

      def test_unreachable_host_raises_connection_error
        bad = Host.new(HOST)
        bad.port = 1
        err = assert_raises(OpenSSH::ConnectionError) { run_on(bad) { execute :true } }
        assert_match(/refused|port 1/i, err.message)
      end

      def test_pty_with_closed_stdin_runs_to_completion
        OpenSSH.config.pty = true
        assert_equal 'done', run_on_capture { capture('sleep 1; echo done') }
      end

      def test_interaction_handler_answers_prompt
        out = run_on_capture do
          capture('printf "Name: "; read n; echo "hi $n"', interaction_handler: { 'Name: ' => "nate\n" })
        end
        assert_equal 'Name: hi nate', out
      end

      def test_close_all_removes_masters_and_socket_dir
        run_on { capture(:true) }
        socket = socket_for
        OpenSSH.masters.close_all
        refute File.exist?(socket)
        refute File.exist?(File.dirname(socket))
      end

      private

      def run_on_capture(&block)
        result = nil
        OpenSSH.new(a_host) { result = instance_exec(&block) }.run
        result
      end
    end
  end
end
