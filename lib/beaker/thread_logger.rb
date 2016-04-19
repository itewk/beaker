module Beaker
    # The Beaker ThreadLogger class.
    # This class handles multi-threaded message reporting for Beaker.
    # It reports based upon a provided log level to given destinations (be it string(s) or file(s)).
    # It extends the functionality of the Beaker::Logger class by making all operations thread safe.
    # This includes making sure the destinations are logged to in a thread safe manor as well as
    # insuring all functions such as sublogs, line prefixes, and last result are tracked separately per thread.
    # It also adds the option to temporarily log all messages from threads other then Thread.main to buffers
    # which can then be flushed on demand to either the destinations or another threads buffer.
    #
    # This functionality allows Beaker tests to be run in parallel or for beaker tests to do parallel operations
    # while still outputting sane logs that are not intermixed with multiple threads running as the user decides
    # when each thread will actually log its buffer to the given destinations.
  class ThreadLogger < Logger

    #true to buffer logs from child threads, or false to log from threads in real time
    attr_accessor :buffer_thread_logs

    # Initialization of the Logger class
    # @overload initialize(dests)
    #   Initialize a Logger object that reports to the provided destinations, use default options
    #   @param [Array<String, IO>] Array of IO and strings (assumed to be file paths) to be reported to
    # @overload initialize(dests, options)
    #   Initialize a Logger object that reports to the provided destinations, use options from provided option hash
    #   @param [Array<String, IO>] Array of IO and strings (assumed to be file paths) to be reported to
    #   @param [Hash] options Hash of options
    #   @option options [Boolean] :color (true) Print color code before log messages
    #   @option options [Boolean] :quiet (false) Do not log messages to STDOUT
    #   @option options [String] :log_level ("info") Log level (one of "debug" - highest level, "verbose", "info",
    #                            "notify" and "warn" - lowest level (see {LOG_LEVELS}))  The log level indicates that messages at that
    #                            log_level and lower will be reported.
    #   @option options [Boolean] :buffer_thread_logs (true) Create separate log buffers for threads other then Thread.main
    #                             to be flushed on demand as need by Beaker::ThreadLogger#flush_thread_buffer
    def initialize(*args)
      options = args.last.is_a?(Hash) ? args.last : {}
      @buffer_thread_logs     = options.key?(:buffer_thread_logs) ? options[:buffer_thread_logs] : true
      @thread_buffers         = {}
      @thread_sublogs         = {}
      @thread_last_results    = {}
      @thread_line_prefixes   = Hash.new('')
      @destinations_semaphore = Mutex.new

      super
    end

    # If the @buffer_thread_logs option is true then all logging for threads other then Thread.main are logged
    # to independent thread buffers. This function is used to flush those buffers to either to this ThreadLoggers
    # destinations or to another Threads buffer.
    #
    # This allows the user to specify when a threads log will be logged to the destinations or merged into another
    # threads logs. The result is that the logs can be printed in a *sane* and *readable* way rather then the logs
    # for multiple threads all showing up in the destinations in an indeterminate order.
    # 
    # @param [Thread] thread             (Thread.current) The Thread to flush the log for.
    # @param [Thread] destination_thread (Thread.main)    The destination Thread to flush the log to.
    #                                                     Ignored if @buffer_thread_logs is false.
    def flush_thread_buffer(thread = Thread.current, destination_thread = Thread.main)
      thread_buffer = @thread_buffers.delete(thread)
      
      if thread_buffer
        thread_buffer.rewind
        thread_log = thread_buffer.read

        # if destination thread is main thread then flush directly to destinations
        # else destination thread is another Thread flush the log to that Threads buffer
        if !@buffer_thread_logs || destination_thread == Thread.main
          @destinations_semaphore.synchronize do
            self.destinations.each do |to|
              to.print thread_log
              to.flush
            end
          end
        else
          @thread_buffers[destination_thread] ||= StringIO.new
          @thread_buffers[destination_thread].print thread_log
        end
      end
    end

    # Thread safe implementation of Beaker::Logger#line_prefix
    # @param [Thread] thread (Thread.current) Thread to get the line prefix for.
    # @return [String] the line prefix for the current thread
    def line_prefix(thread = Thread.current)
      @thread_line_prefixes[thread]
    end

    # Thread safe implementation of Beaker::Logger#line_prefix=
    # @param [String] line_prefix sets the line prefix specific to the current Thread
    # @param [Thread] thread (Thread.current) Thread to set the line prefix for.
    def line_prefix=(line_prefix, thread = Thread.current)
      @thread_line_prefixes[thread] = line_prefix
    end

    # Thread safe implementation of Beaker::Logger#last_result
    # @param [Thread] thread (Thread.current) Thread to get the last result for.
    # @return [String] the last result specific to the current Thread
    def last_result(thread = Thread.current)
      @thread_last_results[thread]
    end

    # Thread safe implementation of Beaker::Logger#last_result=
    # @param [String] last_result sets the last result specific to the current Thread
    # @param [Thread] thread (Thread.current) Thread to set the last result for.
    def last_result=(last_result, thread = Thread.current)
      @thread_last_results[thread] = last_result
    end

    # Thread safe implementation of Beaker::Logger#destinations
    # @return [Array<IO, String>] Array of destinations including the current thread's sublog if one exists
    def destinations
      if @thread_sublogs[Thread.current]
        @destinations + [@thread_sublogs[Thread.current]]
      else
        @destinations
      end
    end

    # Thread safe implementation of Beaker::Logger#add_destination
    # @see Beaker::Logger#add_destination
    def add_destination(dest)
      @destinations_semaphore.synchronize do
        super(dest)
      end
    end
 
    # Thread safe implementation of Beaker::Logger#remove_destination
    # @see Beaker::Logger#remove_destination
    def remove_destination(dest)
      @destinations_semaphore.synchronize do
        super(dest)
      end
    end

    # Thread safe implementation of Beaker::Logger#start_sublog
    # Starts a new sub log specific to the current Thread.
    # @param [Thread] thread (Thread.current) Thread to start a sublog for.
    # @see Beaker::Logger#start_sublog
    def start_sublog(thread = Thread.current)
      @thread_sublogs[thread] = StringIO.new
    end

    # Thread safe implementation of Beaker::Logger#get_sublog
    # Gets and deletes the sublog specific to the current thread.
    # @param [Thread] thread (Thread.current) Thread to get and delete the sublog for.
    # @return [String] the sublog specific to the current Thread.
    # @see Beaker::Logger#get_sublog
    def get_sublog(thread = Thread.current)
      thread_sublog = @thread_sublogs.delete(thread)
      if thread_sublog
        thread_sublog.rewind
        thread_sublog.read
      end
    end

    # Thread safe implementation of Beaker::Logger#optionally_color
    # Print the provided message to the set destination streams, using color codes if appropriate.
    # If @buffer_htread_logs is true and not on the main process thread then log
    # to a StringIO buffer to flush on demand by calling Beaker::LoggerThread#flush_thread_buffer
    #
    # @param [String] color_code The color code to pre-pend to the message
    # @param [String] msg The message to be reported
    # @param [Boolean] add_newline (true) Add newlines between the color codes and the message
    # @param [Thread] thread (Thread.current) Thread to print the provided message for.
    #
    # @see Beaker::Logger#optionally_color
    # @see Beaker::ThreadLogger#flush_thread_buffer
    def optionally_color color_code, msg, add_newline = true, thread = Thread.current
      print_statement = add_newline ? :puts : :print
      msg = convert(msg)
      msg = prefix_log_line(msg)

      # if not buffer thread logs or current thread is the main thread log directly to the logger destinations
      # else log to thread buffer
      if !@buffer_thread_logs || thread == Thread.main
        @destinations_semaphore.synchronize do
          self.destinations.each do |to|
            to.print color_code if @color
            to.send print_statement, msg 
            to.print NORMAL if @color unless color_code == NONE
            to.flush
          end 
        end
      else
        @thread_buffers[thread] ||= StringIO.new
        @thread_buffers[thread].print color_code if @color
        @thread_buffers[thread].send print_statement, msg 
        @thread_buffers[thread].print NORMAL if @color unless color_code == NONE
        @thread_buffers[thread].flush
      end
    end 
  end
end
