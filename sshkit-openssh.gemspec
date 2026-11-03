require_relative 'lib/sshkit/openssh/version'

Gem::Specification.new do |gem|
  gem.name          = 'sshkit-openssh'
  gem.version       = SSHKit::OpenSSH::VERSION
  gem.authors       = ['Nate Vack']
  gem.summary       = 'SSHKit backend that runs commands through the system ssh binary'
  gem.description   = 'An SSHKit backend (usable from Capistrano) that shells out to OpenSSH, ' \
                      'multiplexing commands over a ControlMaster connection per host.'
  gem.homepage      = 'https://github.com/njvack/sshkit-openssh'
  gem.license       = 'MIT'
  gem.metadata      = { 'rubygems_mfa_required' => 'true' }

  gem.files         = Dir['lib/**/*.rb', 'LICENSE', 'README.md']
  gem.require_paths = ['lib']
  gem.required_ruby_version = '>= 2.7'

  gem.add_runtime_dependency 'sshkit', '~> 1.21'

  gem.add_development_dependency 'minitest', '>= 5.0'
  gem.add_development_dependency 'minitest-reporters'
  gem.add_development_dependency 'rake'
end
