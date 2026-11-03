require 'bundler/setup'
require 'minitest/autorun'
require 'minitest/reporters'
require 'sshkit'
require 'sshkit/openssh'

Minitest::Reporters.use!(Minitest::Reporters::DefaultReporter.new)

class UnitTest < Minitest::Test
  def setup
    SSHKit.reset_configuration!
  end
end
