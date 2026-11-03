module SSHKit
  module Backend
    class OpenSSH < Abstract
      # Turns a Host plus Net::SSH-style ssh_options into ssh command-line
      # arguments. Unset options produce no flags, so ssh_config stays in
      # charge of anything SSHKit was not told about.
      #
      # This covers the options needed to connect; the full Net::SSH option
      # table is a later milestone.
      class OptionMapper
        def initialize(host, config)
          @host = host
          @config = config
        end

        def to_args
          args = []
          args.push('-l', user.to_s) if user
          args.push('-p', options[:port].to_s) if options[:port]
          Array(options[:keys]).each { |key| args.push('-i', File.expand_path(key.to_s)) }
          add_option(args, 'IdentitiesOnly', yes_no(options[:keys_only])) if options.key?(:keys_only)
          add_option(args, 'ForwardAgent', yes_no(options[:forward_agent])) if options.key?(:forward_agent)
          add_option(args, 'ConnectTimeout', timeout) if timeout
          # Hide chatter such as "Shared connection to host closed." unless the
          # user asked for a log level themselves.
          add_option(args, 'LogLevel', 'ERROR') unless log_level_given?
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

        def timeout
          (options[:timeout] || @config.connection_timeout)&.to_i
        end

        def log_level_given?
          extra = Array(@config.ssh_args) + Array(options[:openssh_args])
          extra.any? { |arg| arg.to_s =~ /\A-v+\z|LogLevel/i }
        end

        def add_option(args, key, value)
          args.push('-o', "#{key}=#{value}")
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
