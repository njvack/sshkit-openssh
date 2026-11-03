# sshkit-openssh

An experimental [SSHKit](https://github.com/capistrano/sshkit) backend that runs commands through the system `ssh` binary instead of Net::SSH. Commands to each host share one OpenSSH ControlMaster connection, so per-command overhead stays low, and everything in your `~/.ssh/config` (ProxyJump, `Match`, certificates, FIDO keys, hardware-backed agents) works as it does on the command line.

Status: proof of concept. Linux and macOS only; native Windows is not supported (use WSL).

## Usage

```ruby
# Gemfile
gem 'sshkit-openssh', github: 'njvack/sshkit-openssh'
```

Capistrano:

```ruby
require 'sshkit/openssh'
set :sshkit_backend, SSHKit::Backend::OpenSSH
```

Plain SSHKit:

```ruby
require 'sshkit'
require 'sshkit/openssh'
SSHKit.config.backend = SSHKit::Backend::OpenSSH
```

## Configuration

```ruby
SSHKit::Backend::OpenSSH.configure do |c|
  c.idle_timeout = 30         # ControlPersist seconds; 0 disables multiplexing
  c.ssh_path = 'ssh'
  c.ssh_args = []             # extra arguments for every ssh invocation
  c.pty = false               # ssh -tt
  c.connection_timeout = nil  # ConnectTimeout
  c.ssh_options = {}          # Net::SSH-style options, translated to ssh flags
end
```

Per-host raw arguments can go in `ssh_options[:openssh_args]`.

## ssh_options mapping

Net::SSH-style options (from `ssh_options`, Capistrano's `set :ssh_options`, and per-server options) are translated to `ssh` flags. Options you do not set produce no flags, so your ssh_config decides.

| Net::SSH option | ssh |
| --- | --- |
| `user`, `port`, `keys` | `-l`, `-p`, `-i` |
| `keys_only`, `forward_agent`, `compression`, `non_interactive`, `check_host_ip` | `IdentitiesOnly`, `ForwardAgent`, `Compression`, `BatchMode`, `CheckHostIP` |
| `encryption`, `hmac`, `kex`, `host_key`, `auth_methods` | `Ciphers`, `MACs`, `KexAlgorithms`, `HostKeyAlgorithms`, `PreferredAuthentications` |
| `host_key_alias`, `host_name`, `bind_address`, `number_of_password_prompts`, `rekey_limit` | same names |
| `timeout` / `connection_timeout` | `ConnectTimeout` |
| `keepalive`, `keepalive_interval`, `keepalive_maxcount` | `ServerAliveInterval`, `ServerAliveCountMax` |
| `verify_host_key` / `paranoid` | `StrictHostKeyChecking` (`:never` also sets `UserKnownHostsFile=/dev/null`) |
| `user_known_hosts_file`, `global_known_hosts_file` | same names |
| `use_agent: false` | `IdentityAgent=none` |
| `send_env` (simple regexps), `set_env` | `SendEnv`, `SetEnv` |
| `proxy: Net::SSH::Proxy::Jump` / `Command` | `ProxyJump` / `ProxyCommand` |
| `config: false` / path | `-F /dev/null` / `-F path` |
| `verbose` | `LogLevel` (default `ERROR`) |

Other proxy types raise an error. `password`, `passphrase`, `key_data` and unknown options are ignored with a one-time warning.

## Not yet supported

- `upload!` / `download!`
- Password and key-passphrase auth (use keys and ssh-agent)

## Tests

```sh
bundle exec rake test:units
SSHKIT_OPENSSH_TEST_HOST=deployer@127.0.0.1:2122 SSHKIT_OPENSSH_TEST_KEY=~/.ssh/test_key bundle exec rake test:functional
```

Functional tests need a reachable sshd whose user has passwordless sudo.
