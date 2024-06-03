require 'syslog'
require 'docker_events_dispatcher/validation_helpers'

module DockerEventsDispatcher
  class Logger
    module ConstMapper
      def [](key)
        @map ||= constants.inject({}){ |h, c| h[c.downcase.to_sym] = const_get(c); h }.freeze
        @map[key]
      end

      def keys
        @keys ||= constants.map{ |c| c.downcase.to_sym }
      end

      def each_pair(&blk)
        @pairs ||= keys.map{ |k| [k, self[k]] }
        @pairs.each(&blk)
      end
    end

    module LogLevels
      SILENT  = 0 ## No output even warnings and errors
      QUIET   = 1 ## Output only warnings and errors
      NORMAL  = 2 ## Normal
      VERBOSE = 3 ## Include verbose messages
      DEBUG   = 4 ## Include debug messages and all other messages

      extend ConstMapper
    end

    module LogLevelNotes
      SILENT  = "No output even warnings and errors"
      QUIET   = "Output only warnings and errors"
      NORMAL  = "Includes normal messages, warnings and errors"
      VERBOSE = "Includes verbose messages"
      DEBUG   = "Includes debug messages and all other messages"

      extend ConstMapper
    end

    module MethodLevels
      MESSAGE = LogLevels::NORMAL
      WARNING = LogLevels::QUIET
      ERROR   = LogLevels::QUIET
      DEBUG   = LogLevels::DEBUG
      FATAL   = LogLevels::QUIET
      VERBOSE = LogLevels::VERBOSE

      extend ConstMapper
    end

    module Validators
      def validate_log_file(file)
        raise ArgumentError, "Invalid log file object." unless file.is_a?(IO)
        file
      end

      def validate_syslog(syslog)
        raise ArgumentError, "Invalid syslog object." unless syslog == Syslog
        syslog
      end

      def validate_and_convert_log_level(level)
        log_level_valid = false

        if level.is_a?(Integer)
          log_level_valid = level >= LogLevels::SILENT && level <= LogLevels::DEBUG
        else
          if level.is_a?(String) && /^[[:alpha:]]+$/ =~ level
            level = level.downcase.to_sym
          end

          if level.is_a?(Symbol)
            level = LogLevels[level] || MethodLevels[level]
            log_level_valid = !level.nil?
          end
        end

        raise ArgumentError, "Invalid log level." unless log_level_valid
        level
      end
    end

    module Defaults
      LOG_FILE              = nil
      LOG_LEVEL             = LogLevels::NORMAL
      LOG_LEVEL_FILE        = LogLevels::NORMAL
      LOG_LEVEL_SYSLOG      = LogLevels::QUIET
      NO_STDERR             = false
      NO_STDOUT             = false
      SYSLOG_LOGGER         = nil
      SYSLOG_NO_TYPE_PREFIX = false
      SYSLOG_PREFIX         = nil
      USE_HOLD_BUFFER       = false

      extend ConstMapper
    end

    module Options
      include Validators
      include ValidationHelpers

      validated_accessor :log_file
      validated_accessor :syslog
      validated_accessor :log_level, :validate_and_convert_log_level
      validated_accessor :log_level_file, :validate_and_convert_log_level
      validated_accessor :log_level_syslog, :validate_and_convert_log_level

      attr_accessor :no_stderr
      attr_accessor :no_stdout
      attr_accessor :syslog_no_type_prefix
      attr_accessor :syslog_prefix

      def self.initialize_instance(instance, **opts)
        instance.instance_eval do
          Defaults.each_pair do |key, default|
            value = opts[key]
            value ? send("#{key}=", value) : instance_variable_set("@#{key}", default)
          end

          self
        end
      end
    end

    include Options

    class QueuedMessage < Struct.new(:msg, :level, :syslog_level, :opts)
      def initialize(msg, level, syslog_level, **opts)
        super(msg, level, syslog_level, opts)
      end
    end

    def initialize(**opts)
      Options.initialize_instance(self, **opts)
      @queue = []
      @semaphore = Mutex.new
    end

    class LoggingError < StandardError
    end

    class MultipleLoggingErrors < LoggingError
      def initialize(exceptions)
        @exceptions = exceptions
        super()
      end

      def message
        combined_messages = @exceptons.map(&:message).join("; ")
        "Multiple logging errors: #{combined_messages}"
      end
    end

  private
    def log_internal(msg, level, syslog_level, no_syslog: false, prefix: nil, stderr: false,
        syslog_only: false, &blk)
      msg_with_prefix = prefix ? "#{prefix}: #{msg}" : msg

      if no_syslog && syslog_only
        raise ArgumentError, "Can't have both no_syslog and syslog_only enabled."
      end

      exceptions = []

      if level <= @log_level && !syslog_only && !@disable_stdout_and_stderr
        begin
          if stderr
            $stderr.puts(msg_with_prefix) unless no_stderr
          else
            $stdout.puts(msg_with_prefix) unless no_stdout
          end
        rescue SystemCallError => ex
          @disable_stdout_and_stderr = true
          exceptions << LoggingError.new(
              "Failed to write message to #{stderr ? "stderr" : "stdout"}: #{ex.message}")
        rescue Exception
          @disable_stdout_and_stderr = true
          raise
        end
      end

      if @log_file && level <= @log_level_file && !@disable_log_file
        begin
          @log_file.puts "[#{Time.now.strftime('%F %T')}] #{msg_with_prefix}"
          @log_file.flush
        rescue SystemCallError => ex
          @disable_log_file = true
          exceptions << LoggingError.new("Failed to write message file: #{ex.message}")
        rescue Exception
          @disable_log_file = true
          raise
        end
      end

      if @syslog && level <= @log_level_syslog && !no_syslog && !@disable_syslog
        syslog_msg = "#{syslog_prefix || ''}#{syslog_no_type_prefix ? msg_with_prefix : msg}"

        begin
          @syslog.log(syslog_level, "%s", syslog_msg)
        rescue SystemCallError => ex
          @disable_syslog = true
          exceptions << LoggingError.new("Failed to write message syslog: #{ex.message}")
        rescue Exception
          @disable_syslog = true
          raise
        end
      end

      unless exceptions.empty?
        if exceptions.size > 1
          raise MultipleLoggingErrors, exceptions
        else
          raise exceptions.shift
        end
      end

      self
    end

  public
    def dequeue
      while queued_message = @queue.shift
        log_internal(queued_message.msg, queued_message.level, queued_message.syslog_level,
            **queued_message.opts)
      end
    rescue Exception
      @disable_queuing = @skip_queue_once = true
      raise
    end

    def log(msg, level, syslog_level, **opts, &blk)
      @semaphore.synchronize do
        msg = block_given? ? blk.call : msg.to_s
        message_queued = false
        do_queue = opts.delete(:queue)

        if do_queue && !@disable_queuing || !@queue.empty? && !@skip_queue_once
          if do_queue && !@disable_queuing
            @queue << QueuedMessage.new(msg, level, syslog_level, **opts)
            message_queued = true
          else
            dequeue
          end
        end

        @skip_queue_once = false
        log_internal(msg, level, syslog_level, **opts) unless message_queued
      end
    end

    if false
      def log_file=(file)
        super(file).tap do |file|
          if use_hold_buffer && !@hold_buffer.empty?
            file.puts @hold_buffer
            @hold_buffer.clear
          end
        end
      end
    end

    def message(msg = nil, **opts, &blk)
      log(msg, MethodLevels::MESSAGE, Syslog::LOG_INFO, **opts, &blk)
    end

    def warning(msg = nil, **opts, &blk)
      log(msg, MethodLevels::WARNING, Syslog::LOG_WARNING, **opts, prefix: "Warning", &blk)
    end

    def error(msg = nil, **opts, &blk)
      log(msg, MethodLevels::ERROR, Syslog::LOG_ERR, **opts, stderr: true, prefix: "Error", &blk)
    end

    def verbose(msg = nil, **opts, &blk)
      log(msg, MethodLevels::VERBOSE, Syslog::LOG_INFO, **opts, &blk)
    end

    def debug(msg = nil, **opts, &blk)
      if @log_level >= LogLevels::DEBUG
        log(msg, MethodLevels::DEBUG, Syslog::LOG_DEBUG, **opts, prefix: "Debug", &blk)
      end

      self
    end

    def fatal(msg = nil, **opts, &blk)
      log(msg, MethodLevels::FATAL, Syslog::LOG_CRIT, **opts, prefix: "Fatal", &blk)
    end

    def separator(width = 20)
      log("-" * width, MethodLevels::NORMAL, nil, no_syslog: true)
    end
  end
end
