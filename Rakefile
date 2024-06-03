unless $argv
  rake_args = ARGV.empty? ? [] : ARGV.take_while{ |a| a != "--" }

  if rake_args.size == ARGV.size
    $argv = []
  else
    Dir.chdir Rake.original_dir
    $argv = ARGV[(rake_args.size + 1)..]

    Rake.with_application do |application|
      application.run(rake_args)
    end

    exit
  end
end

require 'bundler/gem_tasks'

desc "Run docker-events-dispatcher"
task :run do
  require 'docker_events_dispatcher'
  DockerEventsDispatcher.run(*$argv)
end

task b: :build
task r: :run
