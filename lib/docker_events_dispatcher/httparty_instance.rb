require 'docker_events_dispatcher/constants'
require 'docker_events_dispatcher/http_timeout_attribute'
require 'docker_events_dispatcher/unix_socket_http'
require 'httparty'

module DockerEventsDispatcher
  class HTTPartyInstance
    include HTTParty

    class ConnectionAdapter < HTTParty::ConnectionAdapter
      def connection
        super().tap(&method(:common_connection_setup))
      end

    private
      def add_timeout?(timeout)
        timeout.nil? || timeout.is_a?(Integer) || timeout.is_a?(Float)
      end

      def common_connection_setup(http)
        http.singleton_class.include(HTTPTimeoutAttribute)

        [:timeout, :open_timeout, :read_timeout, :write_timeout, :continue_timeout].each do |sym|
          value = (options.has_key?(sym) && add_timeout?(options[sym])) ? options[sym] :
              Constants::COMMON_INITIAL_TIMEOUT
          http.send("#{sym}=", value)
        end

        http.max_retries = options[:max_retries] if add_max_retries?(options[:max_retries])
        http.set_debug_output(options[:debug_output]) if options[:debug_output]
        http.ciphers = options[:ciphers] if options[:ciphers]
      end
    end

    default_options[:connection_adapter] = ConnectionAdapter
    default_options[:timeout] = nil

    class UnixSocketConnectionAdapter < ConnectionAdapter
      def connection
        UnixSocketHTTP.new(options[:socket_uri]).tap(&method(:common_connection_setup))
      end
    end
  end
end
