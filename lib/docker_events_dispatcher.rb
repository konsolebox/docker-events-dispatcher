require 'docker_events_dispatcher/main'

module DockerEventsDispatcher
  def self.run(*args)
    Main.instance.main(*args)
  end
end
