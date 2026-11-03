# sshkit-openssh

An experimental [SSHKit](https://github.com/capistrano/sshkit) backend that runs commands through the system `ssh` binary instead of Net::SSH. Commands to each host share one OpenSSH ControlMaster connection, so per-command overhead stays low, and everything in your `~/.ssh/config` (ProxyJump, `Match`, certificates, FIDO keys, hardware-backed agents) works as it does on the command line.

Status: proof of concept. Linux and macOS only; native Windows is not supported (use WSL).

## Usage

```ruby
# Gemfile
gem 'sshkit-openssh', github: 'njvack/sshkit-openssh', tag: 'v0.1.0'
```

It is not published on rubygems.org yet; Bundler installs it from GitHub. Drop `tag:` to track `main`.

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

## File transfers

`upload!` and `download!` run over the same connection as commands. Files and IO objects (such as `StringIO`) stream through `cat`; `recursive: true` directories go through `tar`. This needs `cat`, `tar` and `mkdir` on the remote host and does not use scp or sftp, so `transfer_method` is ignored. As with scp, a destination that is an existing directory receives the source under its own name. `download!` with no local path returns the contents as a String. Upload progress is logged at each `log_percent` step (default 10).

## Not supported

- **Password, key passphrase and keyboard-interactive auth.** This is deliberate: OpenSSH reads these only from a terminal. Use keys, ssh-agent, or certificates. `password` and `passphrase` in `ssh_options` are ignored with a warning.
- **`key_data`.** Write the key to a file and use `keys:`, or load it into ssh-agent.
- **SOCKS and HTTP proxy objects.** `Net::SSH::Proxy::Jump` and `Command` work; other proxy classes raise. Use `ProxyCommand` in ssh_config for the rest.
- **`transfer_method: :scp/:sftp` and `preserve:`.** Transfers always use `cat`/`tar`.
- **Project-local `.ssh/config`.** Netssh also reads `./.ssh/config`; this backend uses only what `ssh` reads (or `ssh_options[:config]`).
- **Net::SSH-only options** such as `logger` or `agent_socket_factory`, which are ignored with a warning.
- **Native Windows.** Win32-OpenSSH lacks ControlMaster, and the backend raises `UnsupportedPlatformError` when used there (requiring the gem is harmless, so `set :sshkit_backend, Gem.win_platform? ? SSHKit::Backend::Netssh : SSHKit::Backend::OpenSSH` works for mixed teams). Run Capistrano inside WSL instead: it is Linux, so everything above applies. Keep your Ruby, Bundler and keys on the WSL side (or bridge the Windows ssh-agent, e.g. with 1Password's WSL integration or npiperelay). Projects on `/mnt/c` are fine because control sockets live in `/tmp`.

## Tests

```sh
bundle exec rake test:units    # no network; uses a fake ssh that runs commands locally
bundle exec rake test:docker   # functional tests against a throwaway sshd container
```

`test:docker` builds `test/docker/Dockerfile` with a generated key and publishes it on 127.0.0.1:2122 (override with `SSHKIT_OPENSSH_TEST_PORT`). To use your own server instead, set `SSHKIT_OPENSSH_TEST_HOST` (and optionally `SSHKIT_OPENSSH_TEST_KEY`) and run `rake test:functional`; the user needs passwordless sudo.
