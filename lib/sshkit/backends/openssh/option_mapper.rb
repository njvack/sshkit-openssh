require 'set'

module SSHKit
  module Backend
    class OpenSSH < Abstract
      # Turns a Host plus Net::SSH-style ssh_options into ssh command-line
      # arguments. Unset options produce no flags, so ssh_config stays in
      # charge of anything SSHKit was not told about.
      #
      # Options OpenSSH has no equivalent for are dropped with a warning
      # (once per option per process) rather than failing the deploy, since
      # Capistrano configs often carry options for Net::SSH's benefit only.
      class OptionMapper
        # Net::SSH option => ssh_config keyword, for options whose value is a
        # string or a list joined with commas.
        LIST_OPTIONS = {
          encryption: 'Ciphers',
          hmac: 'MACs',
          kex: 'KexAlgorithms',
          host_key: 'HostKeyAlgorithms',
          auth_methods: 'PreferredAuthentications'
        }.freeze

        # Net::SSH option => ssh_config keyword, for scalar values.
        SCALAR_OPTIONS = {
          host_key_alias: 'HostKeyAlias',
          host_name: 'HostName',
          bind_address: 'BindAddress',
          number_of_password_prompts: 'NumberOfPasswordPrompts',
          rekey_limit: 'RekeyLimit'
        }.freeze

        # Net::SSH option => ssh_config keyword, for booleans.
        BOOLEAN_OPTIONS = {
          keys_only: 'IdentitiesOnly',
          forward_agent: 'ForwardAgent',
          compression: 'Compression',
          non_interactive: 'BatchMode',
          check_host_ip: 'CheckHostIP'
        }.freeze

        # Handled elsewhere or meaningless for the ssh binary.
        IGNORED_OPTIONS = %i[
          user port keys timeout logger known_hosts openssh_args
          verify_host_key paranoid user_known_hosts_file global_known_hosts_file
          keepalive keepalive_interval keepalive_maxcount
          use_agent send_env set_env verbose config proxy
          password passphrase key_data
        ].freeze

        UNSUPPORTED_OPTIONS = {
          password: 'OpenSSH reads passwords only from a terminal; use key or agent auth',
          passphrase: 'load the key into ssh-agent instead',
          key_data: 'write the key to a file and use :keys, or load it into ssh-agent'
        }.freeze

        # Net::SSH verify_host_key / paranoid values => StrictHostKeyChecking.
        HOST_KEY_POLICIES = {
          'never' => 'no', 'false' => 'no',
          'accept_new' => 'accept-new', 'very' => 'accept-new',
          'accept_new_or_local_tunnel' => 'accept-new', 'true' => 'accept-new',
          'always' => 'yes', 'secure' => 'yes'
        }.freeze

        LOG_LEVELS = {
          debug: 'DEBUG3', info: 'INFO', warn: 'ERROR', error: 'ERROR', fatal: 'FATAL'
        }.freeze

        @warned = Set.new
        @warn_lock = Mutex.new

        class << self
          # Warn once per message per process.
          def warn_once(message)
            first = @warn_lock.synchronize { @warned.add?(message) }
            SSHKit.config.output.warn(message) if first
          end

          def reset_warnings!
            @warn_lock.synchronize { @warned.clear }
          end
        end

        def initialize(host, config)
          @host = host
          @config = config
        end

        def to_args
          args = []
          args.push('-F', ssh_config_file) if ssh_config_file
          args.push('-l', user.to_s) if user
          args.push('-p', options[:port].to_s) if options[:port]
          Array(options[:keys]).each { |key| args.push('-i', File.expand_path(key.to_s)) }
          map_simple_options(args)
          map_connection_options(args)
          map_host_key_options(args)
          map_environment_options(args)
          map_proxy(args)
          map_log_level(args)
          warn_about_unsupported
          args.concat(Array(@config.ssh_args).map(&:to_s))
          args.concat(Array(options[:openssh_args]).map(&:to_s))
          args
        end

        # Effective options, with the same precedence as Netssh: host defaults
        # (which include forward_agent: true), then the backend config, then
        # the host's own ssh_options.
        def options
          @options ||= symbolize(@host.netssh_options)
                       .merge(symbolize(@config.ssh_options))
                       .merge(symbolize(@host.ssh_options || {}))
        end

        private

        def user
          options[:user] || @host.username
        end

        def ssh_config_file
          case (config = options[:config])
          when false then '/dev/null'
          when String then File.expand_path(config)
          when Array
            self.class.warn_once('OpenSSH backend: ssh -F takes one file; using the first of ssh_options[:config]')
            File.expand_path(config.first.to_s) unless config.empty?
          end
        end

        def map_simple_options(args)
          BOOLEAN_OPTIONS.each do |key, keyword|
            add_option(args, keyword, yes_no(options[key])) if options.key?(key)
          end
          LIST_OPTIONS.each do |key, keyword|
            add_option(args, keyword, Array(options[key]).join(',')) if options[key]
          end
          SCALAR_OPTIONS.each do |key, keyword|
            add_option(args, keyword, options[key]) if options[key]
          end
          add_option(args, 'IdentityAgent', 'none') if options.key?(:use_agent) && !options[:use_agent]
        end

        def map_connection_options(args)
          timeout = (options[:timeout] || @config.connection_timeout)&.to_i
          add_option(args, 'ConnectTimeout', timeout) if timeout
          return unless options[:keepalive]

          # Net::SSH defaults: 300 s interval, 3 missed replies.
          add_option(args, 'ServerAliveInterval', (options[:keepalive_interval] || 300).to_i)
          add_option(args, 'ServerAliveCountMax', (options[:keepalive_maxcount] || 3).to_i)
        end

        def map_host_key_options(args)
          policy_key = options.key?(:verify_host_key) ? :verify_host_key : (:paranoid if options.key?(:paranoid))
          if policy_key
            value = options[policy_key]
            policy = HOST_KEY_POLICIES[value.to_s]
            if policy
              add_option(args, 'StrictHostKeyChecking', policy)
              # Net::SSH's :never neither checks nor records keys.
              add_option(args, 'UserKnownHostsFile', '/dev/null') if policy == 'no' && !options[:user_known_hosts_file]
            else
              self.class.warn_once("OpenSSH backend: ignoring #{policy_key}: #{value.inspect}; ssh_config decides")
            end
          end
          { user_known_hosts_file: 'UserKnownHostsFile', global_known_hosts_file: 'GlobalKnownHostsFile' }.each do |key, keyword|
            add_option(args, keyword, Array(options[key]).map { |f| File.expand_path(f.to_s) }.join(' ')) if options[key]
          end
        end

        def map_environment_options(args)
          names = Array(options[:send_env]).filter_map { |pattern| env_pattern(pattern) }
          add_option(args, 'SendEnv', names.join(' ')) unless names.empty?
          set_env = options[:set_env]
          return if set_env.nil? || set_env.empty?

          add_option(args, 'SetEnv', set_env.map { |k, v| "#{k}=#{v}" }.join(' '))
        end

        # Net::SSH takes regexps for send_env; ssh_config takes names with *
        # and ? wildcards. Translate the common forms and warn on the rest.
        def env_pattern(pattern)
          return pattern.to_s unless pattern.is_a?(Regexp)

          name = pattern.source.sub(/\A\^/, '').sub(/\$\z/, '').gsub('.*', '*').gsub('.', '?')
          return name if name =~ /\A[\w*?]+\z/

          self.class.warn_once("OpenSSH backend: cannot translate send_env #{pattern.inspect}; skipping it")
          nil
        end

        # Proxy objects are matched by class name so net-ssh need not be
        # loaded for this backend to work.
        def map_proxy(args)
          proxy = options[:proxy]
          return if proxy.nil?

          case proxy.class.name
          when 'Net::SSH::Proxy::Jump'
            add_option(args, 'ProxyJump', proxy.jump_proxies)
          when 'Net::SSH::Proxy::Command'
            add_option(args, 'ProxyCommand', proxy.command_line_template)
          else
            raise ArgumentError, "OpenSSH backend does not support proxy #{proxy.class}; " \
                                 'use ProxyJump or ProxyCommand in ssh_config or :openssh_args'
          end
        end

        def map_log_level(args)
          return if log_level_given?

          level = LOG_LEVELS.fetch(options[:verbose].to_s.downcase.to_sym, nil) if options[:verbose]
          # By default hide chatter such as "Shared connection to host closed."
          add_option(args, 'LogLevel', level || 'ERROR')
        end

        def log_level_given?
          extra = Array(@config.ssh_args) + Array(options[:openssh_args])
          extra.any? { |arg| arg.to_s =~ /\A-v+\z|LogLevel/i }
        end

        def warn_about_unsupported
          UNSUPPORTED_OPTIONS.each do |key, advice|
            self.class.warn_once("OpenSSH backend: ignoring ssh_options[:#{key}]; #{advice}") if options[key]
          end
          (options.keys - IGNORED_OPTIONS - BOOLEAN_OPTIONS.keys - LIST_OPTIONS.keys - SCALAR_OPTIONS.keys).each do |key|
            self.class.warn_once("OpenSSH backend: ignoring unsupported ssh_options[:#{key}]")
          end
        end

        def add_option(args, keyword, value)
          args.push('-o', "#{keyword}=#{value}")
        end

        def yes_no(value)
          value ? 'yes' : 'no'
        end

        def symbolize(hash)
          hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        end
      end
    end
  end
end
