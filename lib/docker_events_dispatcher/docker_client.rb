require 'docker_events_dispatcher/httparty_instance'
require 'stringio'

module DockerEventsDispatcher
  class DockerClient
    class NonSuccessStatusCodeReceived < StandardError
    end

    def initialize(base_or_socket_uri, log, **options)
      @httparty = Class.new(HTTPartyInstance) do
        default_options.merge!(options)

        if base_or_socket_uri.downcase[0, 7] == "unix://"
          default_options[:connection_adapter] = HTTPartyInstance::UnixSocketConnectionAdapter
          default_options[:socket_uri] = base_or_socket_uri
        else
          base_uri base_or_socket_uri
        end
      end

      @log = log
    end

    def get_events(&callback)
      raise "Callback not given." unless block_given?
      string_io = ::StringIO.new

      @httparty.get("/events", stream_body: true, read_timeout: nil) do |fragment|
        case fragment.code
        when 301, 302
          @log.verbose "Redirecting."
        when 200
          body = fragment.to_s

          unless (index = body.index("\n")).nil?
            event = string_io.eof? ? "" : string_io.read

            begin
              event << body[0..index]
              callback.call(event.chomp)
              body = body[(index + 1)..]
            end until body.nil? || (index = body.index("\n")).nil?
          end

          string_io.write(body) unless body.nil? || body.empty?
        else
          raise NonSuccessStatusCodeReceived, fragment.code.to_s
        end
      end
    end

    def get_version
      @httparty.get("/version").body
    end
  end
end
