module DockerEventsDispatcher
  module HTTPTimeoutAttribute
    def timeout
      @socket ? @socket.timeout : @timeout
    end

    def timeout=(timeout)
      @socket.timeout = timeout if @socket
      @timeout = timeout
    end
  end
end
