module DockerEventsDispatcher
  module BufferedIOTimeoutAttribute
    def timeout
      @io.to_io.timeout
    end

    def timeout=(timeout)
      @io.to_io.timeout = timeout
    end
  end
end
