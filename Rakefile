require 'rake/testtask'

task default: 'test:units'

desc 'Run all tests (functional tests skip unless SSHKIT_OPENSSH_TEST_HOST is set)'
task test: ['test:units', 'test:functional']

namespace :test do
  Rake::TestTask.new(:units) do |t|
    t.libs << 'test'
    t.test_files = FileList['test/unit/**/test_*.rb']
  end

  Rake::TestTask.new(:functional) do |t|
    t.libs << 'test'
    t.test_files = FileList['test/functional/**/test_*.rb']
  end
end

namespace :test do
  desc 'Run functional tests against a throwaway sshd in Docker'
  task :docker do
    require 'fileutils'
    require 'io/wait'
    require 'socket'

    key = File.expand_path('test/tmp/id_ed25519', __dir__)
    image = 'sshkit-openssh-test-sshd'
    container = "sshkit-openssh-sshd-#{Process.pid}"
    port = Integer(ENV.fetch('SSHKIT_OPENSSH_TEST_PORT', '2122'))

    FileUtils.mkdir_p(File.dirname(key))
    sh 'ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key unless File.exist?(key)
    FileUtils.cp("#{key}.pub", 'test/docker/authorized_keys')
    sh 'docker', 'build', '-q', '-t', image, 'test/docker'
    sh 'docker', 'run', '-d', '--rm', '--name', container, '-p', "127.0.0.1:#{port}:22", image
    begin
      # Wait until sshd answers with its banner, not just until the port opens.
      ready = 30.times.any? do
        sleep 0.5
        begin
          Socket.tcp('127.0.0.1', port, connect_timeout: 1) { |s| s.wait_readable(2) && s.gets.to_s.start_with?('SSH-') }
        rescue SystemCallError, IOError
          false
        end
      end
      abort 'sshd container did not come up' unless ready
      ENV['SSHKIT_OPENSSH_TEST_HOST'] = "deployer@127.0.0.1:#{port}"
      ENV['SSHKIT_OPENSSH_TEST_KEY'] = key
      Rake::Task['test:functional'].invoke
    ensure
      sh 'docker', 'stop', container, verbose: false
    end
  end
end
