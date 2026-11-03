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
