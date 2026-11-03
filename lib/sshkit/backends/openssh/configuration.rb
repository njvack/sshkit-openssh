module SSHKit
  module Backend
    class OpenSSH < Abstract
      # Mirrors the parts of Netssh::Configuration that Capistrano writes to
      # (pty, connection_timeout, ssh_options), plus OpenSSH-specific settings.
      class Configuration
        # Request a pty (`ssh -tt`) for every command.
        attr_accessor :pty

        # Seconds; becomes ConnectTimeout. ssh_options[:timeout] takes
        # precedence when both are set.
        attr_accessor :connection_timeout

        # Path to the ssh binary.
        attr_accessor :ssh_path

        # Extra arguments passed verbatim to every ssh invocation, before the
        # destination. Example: ['-o', 'Ciphers=aes256-gcm@openssh.com']
        attr_accessor :ssh_args

        # Seconds an idle ControlMaster stays up (ControlPersist). 0, false or
        # nil disables multiplexing, so each command makes its own connection,
        # like Netssh's ConnectionPool with idle_timeout = 0.
        attr_accessor :idle_timeout

        # Net::SSH-style options; translated to ssh flags by OptionMapper.
        attr_writer :ssh_options

        def initialize
          @pty = false
          @connection_timeout = nil
          @ssh_path = 'ssh'
          @ssh_args = []
          @idle_timeout = 30
        end

        def ssh_options
          @ssh_options ||= {}
        end

        def multiplex?
          idle_timeout ? idle_timeout.to_i.positive? : false
        end
      end
    end
  end
end
