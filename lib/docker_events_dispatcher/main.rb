require 'docker_events_dispatcher/constants'
require 'docker_events_dispatcher/docker_client'
require 'docker_events_dispatcher/logger'
require 'docker_events_dispatcher/validation_helpers'
require 'docker_events_dispatcher/version'
require 'json'
require 'optparse'
require 'singleton'
require 'syslog/logger'
require 'timeout'

module DockerEventsDispatcher
  class Main
    include Singleton

    class Defaults
      HOST_URI = "unix:///var/run/docker.sock"
      IO_ERROR_RETRY = 10
      QUICK_RETRIES = false
      TIMEOUT_ERROR_RETRY = 10
    end

    class Options
      include Logger::Options
      include ValidationHelpers

      def validate_and_convert_seconds(seconds)
        seconds = seconds.to_i rescue nil
        raise ArgumentError, "Invalid seconds argument." unless seconds
        seconds
      end

      def validate_true_or_false(value)
        raise ArgumentError, "Invalid true or false value." unless value == true || value == false
        value
      end

      attr_accessor :enable_syslog, :host_uri, :log_file_path, :overwrite_log_file
      validated_accessor :io_error_retry, :validate_and_convert_seconds
      validated_accessor :timeout_error_retry, :validate_and_convert_seconds
      validated_accessor :quick_retries, :validate_true_or_false

      def initialize
        Logger::Options.initialize_instance(self)
        @enable_syslog = false
        @host_uri = Defaults::HOST_URI
        @io_error_retry = Defaults::IO_ERROR_RETRY
        @log_file_path = nil
        @overwrite_log_file = false
        @timeout_error_retry = Defaults::TIMEOUT_ERROR_RETRY
        @quick_retries = Defaults::QUICK_RETRIES
      end
    end

    def log
      @log ||= Logger.new
    end

    def opts
      @opts ||= Options.new
    end

    def die(msg, exit_code = 1)
      log.fatal msg
      exit exit_code
    end

    def run_hooks(event)
      begin
        parsed = JSON.parse(event)
      rescue JSON::ParserError => ex
        log.error "JSON parse error: #{ex.message}"
        return
      end

      type = parsed['Type'] or begin
        log.error "Event has no type."
        return
      end

      action = parsed['Action'] or begin
        log.error "Event has no action."
        return
      end

      log.verbose do
        sprintf("Event: { \"Type\": %s, \"Action\": %s }", type.to_json, action.to_json)
      end

      log.debug do
        "Event details: " + parsed.delete_if{ |k, v| k == "Type" || k == "Action" }
            .to_json(object_nl: " ", space: " ")
      end

      Dir.glob("/etc/docker-events-dispatcher.d/*") do |file|
        if File.directory? file
          log.debug("Skipping directory: #{file}")
        end

        unless File.executable? file
          log.verbose("Skipping file: #{file}")
          next
        end

        begin
          file_stat = File.stat(file)
          uid = file_stat.uid
          gid = file_stat.gid
        rescue SystemCallError => ex
          log.error "Failed to get file stat of '#{file}': #{ex.message}"
        end

        Process.fork do
          unless gid.zero?
            begin
              Process::GID.change_privilege(gid)
            rescue SystemCallError => ex
              log.error "Failed to change group privilege to #{gid}: #{ex.message}"
              return
            end
          end

          unless uid.zero?
            begin
              Process::UID.change_privilege(uid)
            rescue SystemCallError => ex
              log.error "Failed to change user privilege to #{uid}: #{ex.message}"
              return
            end
          end

          begin
            Process.setpgid(0, 0)
          rescue SystemCallError => ex
            log.error "Failed to change process group: #{ex.message}"
            return
          end

          log.debug "Calling file: #{file}"

          begin
            Process.exec(file, type, action, event)
          rescue SystemCallError => ex
            log.error "Failed to execute file: #{ex.message}"
            return
          end
        end.then(&Process.method(:wait))
      end
    end

    def main(*args)
      debug = ENV['DOCKER_EVENTS_DISPATCHER_DEBUG']
      log.log_level = log.log_level_file = :debug if debug && !debug.empty?

      OptionParser.new do |parser|
        parser.on("--debug", "Enable debug mode.  This is equivalent to",
            "setting both log level and log file level to 4.") do
          opts.log_level = opts.log_level_file = :debug
        end

        parser.on("-H", "--host=HOST_URI", "Base host URI or socket URI to connect to.") do |uri|
          opts.host_uri = uri
        end

        parser.on("--io-error-retry=N", "Number of seconds to wait before retrying to",
            "connect to docker after an IO error.",
            "Set to 0 to disable retry.  Default is #{Defaults::IO_ERROR_RETRY}.") do |seconds|
          opts.io_error_retry = seconds
        end

        parser.on("-l", "--log-file=LOG_FILE",
            "Log file to send timestamped copy of messages to") do |file|
          opts.log_file_path = file
        end

        parser.on("--log-file-level=LEVEL", "Level of log messages sent to file.") do |level|
          opts.log_level_file = level
        end

        parser.on("--log-level=LEVEL", "Level of log messages sent to stdout/stderr.") do |level|
          opts.log_level_file = level
        end

        parser.on("--no-stderr", "Disable any output to stderr.") do
          opts.no_stderr = true
        end

        parser.on("--no-stdout", "Disable any output to stdout.") do
          opts.no_stdout = true
        end

        parser.on("-o", "--overwite-log-file",
            "Open log file in overwrite mode instead of ", "append.") do
          opts.overwrite_log_file = true
        end

        parser.on("--[no-]quick-retries", "Enable or disable quick retries.",
            "Quick retries happen if last connection attempt",
            "was specified timeouts ago or later.",
            "Default is #{Defaults::QUICK_RETRIES.to_s}." ) do |value|
          opts.quick_retries = value
        end

        parser.on("-S", "--[no-]syslog", "Enable or disable sending messages to system log.",
            "This is disabled by default.") do |value|
          opts.enable_syslog = value
        end

        parser.on("--syslog-level=LEVEL", "Level of log messages sent to syslog.") do |level|
          opts.log_level_syslog = level
        end

        parser.on("--syslog-prefix=PREFIX", "Prefix inserted at the beginning of every message",
            "sent to syslog.") do |prefix|
          opts.syslog_prefix = prefix
        end

        parser.on("--timeout-error-retry=N", "Number of seconds to wait before retrying to.",
            "connect to docker after a timeout error.",
            "Set to 0 to disable retry.  Default is #{Defaults::TIMEOUT_ERROR_RETRY}.") do |seconds|
          opts.timeout_error_retry = seconds
        end

        parser.on("-v", "--verbose", "Enable verbose mode.  This is equivalent to",
            "setting both log level and log file level to #{Logger::LogLevels::VERBOSE}.") do
          opts.log_level = opts.log_level_file = :verbose
        end

        parser.on("-h", "--help", "Show this help info and exit.") do
          $stderr.puts "docker-events-dispatcher #{DockerEventsDispatcher::VERSION}"
          $stderr.puts "Listens for events from dockerd and executes executable files in"
          $stderr.puts "'/etc/docker-events-dispatcher.d'."
          $stderr.puts ""
          $stderr.puts "Usage: #{$0} [options]"
          $stderr.puts ""
          $stderr.puts "Options:"
          parser.set_summary_indent("  ")
          $stderr.puts parser.summarize([], 28, 80, "  ")
          $stderr.puts ""
          $stderr.puts "Log levels:"

          Logger::LogLevels.each_pair.sort_by{ |name, level| level }.each do |name, level|
            $stderr.printf "  %-7s (%d) - %s\n", "#{name.to_s.upcase}", level,
                Logger::LogLevelNotes[name]

            default_of = []
            default_of << "stdout/stderr" if level == Logger::Defaults::LOG_LEVEL
            default_of << "log file" if level == Logger::Defaults::LOG_LEVEL_FILE
            default_of << "syslog" if level == Logger::Defaults::LOG_LEVEL_SYSLOG

            unless default_of.empty?
              $stderr.puts "              - #{default_of.join(" and ").capitalize}'s default level"
            end
          end

          exit 2
        end

        parser.on("-V", "--version", "Show version and exit.") do
          $stderr.puts VERSION
          exit 2
        end
      end.parse!(args)

      [:log_level, :log_level_file, :log_level_syslog, :no_stderr, :no_stdout].each do |sym|
        log.send("#{sym}=", opts.send(sym))
      end

      $stdout.close if opts.no_stdout && !$stdout.closed?
      $stderr.close if opts.no_stderr && !$stderr.closed?

      Signal.trap('TERM') do
        Thread.new do
          log.message "SIGTERM caught."
          Thread.main.raise SystemExit, Constants::SIGTERM_EXIT_CODE
        end
      end

      if opts.log_file_path
        begin
          log.log_file = File.open(opts.log_file_path, opts.overwrite_log_file ? 'w' : 'a')
        rescue SystemCallError => ex
          log.error("Failed to open log file '#{opts.log_file_path}': #{ex.message}", queue: true)
        end
      end

      if opts.enable_syslog
        log.syslog_prefix = opts.syslog_prefix

        begin
          log.syslog = Syslog.open('docker-events-dispatcher')
        rescue SystemCallError => ex
          log.error("Failed to open syslog: #{ex.message}", queue: true)
        end
      end

      log.dequeue

      die "Needs to run as EUID 0." unless Process.euid.zero?
      die "Needs to run as EGID 0." unless Process.egid.zero?

      log.message "Started."

      begin
        log.verbose "Connecting to docker."
        @last_retry = Time.now.to_i

        DockerClient.new(opts.host_uri, log).get_events do |event|
          run_hooks(event)
        end
      rescue Exception => ex
        log.debug{ "Caught exception #{ex.class.to_s} (#{ex.message})." }

        case ex
        when IOError
          if opts.io_error_retry != 0
            seconds = opts.quick_retries && Time.now.to_i > @last_retry + opts.io_error_retry ?
                0.1 : opts.io_error_retry
            log.error "IO error; retrying after #{seconds} seconds."
            sleep seconds
            retry
          end
        when Timeout::Error
          if opts.timeout_error_retry != 0
            seconds = opts.quick_retries && Time.now.to_i > @last_retry + opts.timeout_error_retry ?
                0.1 : opts.timeout_error_retry
            log.error "Timeout error; retrying after #{seconds} seconds."
            sleep seconds
            retry
          end
        end

        raise
      end
    rescue ArgumentError => ex
      @no_exiting_message = true
      log.debug{ ex.backtrace.prepend("Backtrace: ").join("\n\t") }
      die "Argument error: #{ex.message.capitalize}"
    rescue SystemExit => ex
      @no_exiting_message = true if ex.status == 2
      raise
    rescue Interrupt
      log.message "SIGINT caught."
      exit Constants::SIGINT_EXIT_CODE
    rescue Exception => ex
      die "Unknown exception caught: #{ex.class.to_s}: #{ex.message.capitalize}"
    ensure
      log.message "Exiting." unless @no_exiting_message

      if log.log_file
        begin
          log.log_file.close
        rescue SystemCallError => ex
          log.error "Failed to close logfile: #{ex.message.capitalize}"
        end
      end
    end
  end
end
