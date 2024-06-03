# Copyright 2024 konsolebox
# Copyright 2016 Authors of NetX::HTTPUnix
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# The DockerEventsDispatcher::UnixSocketHTTP class is implemented based
# on the HTTPUnix class implemented in lib/net_x/http_unix.rb of
# the net_http_unix gem at commit 379a5da3a97534fde72052ebc30b52daa0d71a5b.
#
# See https://github.com/puppetlabs/net_http_unix/blob/379a5da3a97534fde72052ebc30b52daa0d71a5b/lib/net_x/http_unix.rb
# for the referenced code.

require 'docker_events_dispatcher/buffered_io_timeout_attribute'
require 'net/http'
require 'net/protocol'
require 'socket'

module DockerEventsDispatcher
  class UnixSocketHTTP < Net::HTTP
    def initialize(socket_uri, port = nil)
      super(socket_uri, port)

      unless socket_uri[0, 7].downcase == "unix://"
        raise ArgumentError, "Not a UNIX socket URI: #{socket_uri}"
      end

      @socket_path = socket_uri[7..]

      # Address and port are set to localhost so the HTTP client constructs
      # a HOST request header nginx will accept.
      @address = "localhost"
      @port = 80
    end

    def connect
      internal_socket = Timeout.timeout(@open_timeout || @timeout){ UNIXSocket.open(@socket_path) }
      internal_socket.timeout = @timeout

      @socket = Net::BufferedIO.new(internal_socket, read_timeout: @read_timeout,
          write_timeout: @write_timeout, continue_timeout: @continue_timeout,
          debug_output: @debug_output)

      @socket.singleton_class.include(BufferedIOTimeoutAttribute)
      on_connect
    end
  end
end
