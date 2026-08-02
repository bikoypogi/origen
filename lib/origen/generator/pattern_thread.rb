module Origen
  class Generator
    # An instance of PatternThread is created for each parallel thread of execution
    # in a pattern sequence. One instance of this class is also created to represent
    # the original main thread in addition to those created by calling seq.in_parallel
    class PatternThread
      # Returns the parent pattern sequence object
      attr_reader :sequence
      attr_reader :pending_cycles
      attr_reader :id
      attr_reader :reservations
      attr_reader :cycle_count_start
      attr_reader :cycle_count_stop
      # A record of when the thread is active to construct the execution profile
      attr_reader :events

      def initialize(id, sequence, block, primary = false, pre_block = nil)
        if primary
          @cycle_count_start = 0
        else
          @cycle_count_start = current_cycle_count
        end
        @events = [[:active, cycle_count_start]]
        @id = id.to_sym
        @sequence = sequence
        @block = block
        @pre_block = pre_block
        @primary = primary
        @waiting = false
        @pending_cycles = nil
        @completed = false
        @reservations = {}
      end

      # Returns true if this is main thread (the one from which all in_parallel threads
      # have been branched from)
      def primary?
        @primary
      end

      # @api private
      #
      # This method is called once by the pattern sequence to start a new cooperative
      # execution context. Pattern sequences intentionally run only one context at a
      # time to keep generated output deterministic, so an OS thread and two
      # synchronization events only add context-switching overhead. A Fiber provides
      # the same yield/resume behavior without involving the thread scheduler.
      def start
        @fiber = Fiber.new do
          wait
          @pre_block.call if @pre_block
          @block.call(sequence)
          sequence.send(:thread_completed, self)
          record_cycle_count_stop
          @completed = true
          wait
        end
        resume
      end

      def record_cycle_count_stop
        @cycle_count_stop = current_cycle_count
        events << [:stopped, cycle_count_stop]
        events.freeze
      end

      def record_active
        events << [:active, current_cycle_count]
      end

      def current_cycle_count
        tester.try(:cycle_count) || 0
      end

      def execution_profile(start, stop, step)
        events = @events.dup
        cycles = start
        state = :inactive
        line = ''
        ((stop - start) / step).times do |i|
          active_cycles = 0
          while events.first && events.first[1] >= cycles && events.first[1] < cycles + step
            event = events.shift
            # Bring the current cycles up to this event point applying the current state
            if state == :active
              active_cycles += event[1] - cycles
            end
            state = event[0] == :active ? :active : :inactive
            cycles = event[1]
          end

          # Bring the current cycles up to the end of this profile tick
          if state == :active
            active_cycles += ((i + 1) * step) - cycles
          end
          cycles = ((i + 1) * step)

          if active_cycles == 0
            line += '_'
          elsif active_cycles > (step * 0.5)
            line += '█'
          else
            line += '▄'
          end
        end
        line
      end

      # Will be called when the thread can't execute its next cycle because it is waiting to obtain a
      # lock on a serialized block
      def waiting_for_serialize(serialize_id, skip_event = false)
        # puts "Thread #{id} is blocked waiting for #{serialize_id}"
        events << [:waiting, current_cycle_count] unless skip_event
        wait
      end

      # Will be called when the thread can't execute its next cycle because it is waiting for another
      # thread to complete
      def waiting_for_thread(skip_event = false)
        events << [:waiting, current_cycle_count] unless skip_event
        wait
      end

      # Will be called when the thread is ready for the next cycle
      def cycle(options)
        @pending_cycles = options[:repeat] || 1
        # If there are threads pending start and we are about to enter a long delay, block for only
        # one cycle to give them a change to get underway and make use of this delay
        if @pending_cycles > 1 && sequence.send(:threads_waiting_to_start?)
          remainder = @pending_cycles - 1
          @pending_cycles = 1
        end
        loop do
          wait
          if remainder
            @pending_cycles = remainder
            remainder = nil
          end
          # If another context requested fewer cycles, keep yielding the same
          # request until the coordinator has consumed it. The previous recursive
          # call to Integer#cycles retained one Ruby stack frame per partial
          # advance and could overflow on long concurrent delays.
          if @pending_cycles == 0
            @pending_cycles = nil
            break
          elsif @pending_cycles < 0
            fail "Something has gone wrong @pending_cycles is #{@pending_cycles}"
          end
        end
      end

      # @api private
      def executed_cycles(cycles)
        @pending_cycles -= cycles if @pending_cycles
      end

      def completed?
        @completed
      end

      # Returns true if the thread is currently waiting for the pattern sequence to advance it
      def waiting?
        @waiting
      end

      # Yield to the pattern sequence until this context is advanced again.
      def wait
        @waiting = true
        Fiber.yield
        # Thread-local variables are fiber-local on Ruby 2.6, so restore the
        # active context from inside the resumed fiber as well.
        PatSeq.send(:thread=, self)
        @waiting = false
      end

      # Resume this context and return when it reaches its next cycle/wait point.
      def advance(_completed_cycles = nil)
        resume
      end

      private

      def resume
        PatSeq.send(:thread=, self)
        @fiber.resume
      ensure
        # The sequence coordinator generates the combined vector between context
        # advances; it must not look like one of the pattern contexts itself.
        PatSeq.send(:thread=, nil)
      end
    end
  end
end
