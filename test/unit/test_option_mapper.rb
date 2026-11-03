require 'helper'
require 'net/ssh/proxy/command'
require 'net/ssh/proxy/jump'

module SSHKit
  module Backend
    class TestOptionMapper < UnitTest
      def setup
        super
        OpenSSH.instance_variable_set(:@config, nil)
        OpenSSH::OptionMapper.reset_warnings!
        @output = String.new
        SSHKit.config.output = SSHKit::Formatter::SimpleText.new(@output)
      end

      def args_for(ssh_options = {}, host = nil)
        host ||= Host.new(hostname: 'example.com', ssh_options: ssh_options)
        OpenSSH::OptionMapper.new(host, OpenSSH.config).to_args
      end

      def o_flags(args)
        args.each_slice(2).select { |flag, _| flag == '-o' }.map(&:last)
      end

      def assert_option(expected, ssh_options)
        assert_includes o_flags(args_for(ssh_options)), expected
      end

      def test_boolean_options
        assert_option 'IdentitiesOnly=yes', keys_only: true
        assert_option 'Compression=yes', compression: 'zlib@openssh.com'
        assert_option 'Compression=no', compression: false
        assert_option 'BatchMode=yes', non_interactive: true
        assert_option 'CheckHostIP=no', check_host_ip: false
      end

      def test_algorithm_lists_join_with_commas
        assert_option 'Ciphers=aes256-gcm@openssh.com,aes128-ctr', encryption: %w[aes256-gcm@openssh.com aes128-ctr]
        assert_option 'MACs=hmac-sha2-256', hmac: 'hmac-sha2-256'
        assert_option 'KexAlgorithms=curve25519-sha256', kex: ['curve25519-sha256']
        assert_option 'HostKeyAlgorithms=ssh-ed25519', host_key: 'ssh-ed25519'
        assert_option 'PreferredAuthentications=publickey,keyboard-interactive', auth_methods: %w[publickey keyboard-interactive]
      end

      def test_scalar_options
        assert_option 'HostKeyAlias=web', host_key_alias: 'web'
        assert_option 'HostName=10.0.0.5', host_name: '10.0.0.5'
        assert_option 'BindAddress=10.0.0.1', bind_address: '10.0.0.1'
        assert_option 'NumberOfPasswordPrompts=1', number_of_password_prompts: 1
      end

      def test_use_agent_false_disables_identity_agent
        assert_option 'IdentityAgent=none', use_agent: false
        refute_includes o_flags(args_for(use_agent: true)), 'IdentityAgent=none'
      end

      def test_keepalive_uses_net_ssh_defaults
        flags = o_flags(args_for(keepalive: true))
        assert_includes flags, 'ServerAliveInterval=300'
        assert_includes flags, 'ServerAliveCountMax=3'
        flags = o_flags(args_for(keepalive: true, keepalive_interval: 15, keepalive_maxcount: 5))
        assert_includes flags, 'ServerAliveInterval=15'
        assert_includes flags, 'ServerAliveCountMax=5'
        refute(o_flags(args_for(keepalive_interval: 15)).any? { |f| f.start_with?('ServerAlive') })
      end

      def test_verify_host_key_policies
        { never: 'no', accept_new: 'accept-new', accept_new_or_local_tunnel: 'accept-new',
          always: 'yes', secure: 'yes', false => 'no' }.each do |value, policy|
          assert_option "StrictHostKeyChecking=#{policy}", verify_host_key: value
        end
      end

      def test_verify_host_key_never_also_discards_known_hosts
        assert_option 'UserKnownHostsFile=/dev/null', verify_host_key: :never
        flags = o_flags(args_for(verify_host_key: :never, user_known_hosts_file: '/k/hosts'))
        assert_includes flags, 'UserKnownHostsFile=/k/hosts'
        refute_includes flags, 'UserKnownHostsFile=/dev/null'
      end

      def test_legacy_paranoid_option
        assert_option 'StrictHostKeyChecking=no', paranoid: false
        assert_option 'StrictHostKeyChecking=accept-new', paranoid: true
      end

      def test_no_host_key_flag_when_unset
        refute(o_flags(args_for).any? { |f| f.start_with?('StrictHostKeyChecking') })
      end

      def test_known_hosts_files
        assert_option 'UserKnownHostsFile=/a /b', user_known_hosts_file: ['/a', '/b']
        assert_option 'GlobalKnownHostsFile=/etc/hosts_known', global_known_hosts_file: '/etc/hosts_known'
      end

      def test_send_env_translates_simple_regexps
        assert_option 'SendEnv=LANG LC_* RAILS_ENV', send_env: [/^LANG$/, /^LC_.*$/, 'RAILS_ENV']
      end

      def test_send_env_warns_on_untranslatable_regexp
        assert_option 'SendEnv=LANG', send_env: [/^LANG$/, /^(FOO|BAR)$/]
        assert_match(/cannot translate send_env/, @output)
      end

      def test_set_env
        assert_option 'SetEnv=A=1 B=two', set_env: { 'A' => 1, 'B' => 'two' }
      end

      def test_proxy_jump_and_command
        assert_option 'ProxyJump=bastion.example.com', proxy: Net::SSH::Proxy::Jump.new('bastion.example.com')
        assert_option 'ProxyCommand=nc -X connect %h %p', proxy: Net::SSH::Proxy::Command.new('nc -X connect %h %p')
      end

      def test_unsupported_proxy_raises
        fake_socks = Struct.new(:host).new('proxy')
        err = assert_raises(ArgumentError) { args_for(proxy: fake_socks) }
        assert_match(/does not support proxy/, err.message)
      end

      def test_config_file
        assert_equal %w[-F /dev/null], args_for(config: false).first(2)
        assert_equal %w[-F /etc/ssh/deploy_config], args_for(config: '/etc/ssh/deploy_config').first(2)
        refute_includes args_for(config: true), '-F'
      end

      def test_verbose_sets_log_level
        assert_option 'LogLevel=DEBUG3', verbose: :debug
        assert_option 'LogLevel=ERROR', {}
      end

      def test_password_is_dropped_with_one_warning
        host = Host.new(hostname: 'example.com', password: 'secret')
        2.times { refute(args_for({}, host).any? { |a| a.include?('secret') }) }
        assert_equal 1, @output.scan(/ignoring ssh_options\[:password\]/).size
      end

      def test_unknown_options_warn_once
        2.times { args_for(max_pkt_size: 0x8000) }
        assert_equal 1, @output.scan(/ignoring unsupported ssh_options\[:max_pkt_size\]/).size
      end

      def test_known_options_do_not_warn
        args_for(keys: ['/k'], keys_only: true, auth_methods: ['publickey'], forward_agent: false,
                 verify_host_key: :never, timeout: 5, user: 'deploy', port: 22, logger: Object.new)
        assert_empty @output
      end
    end
  end
end
