require 'securerandom'
require 'socket'

module Cucumber
  module Formatter
    class EventStream

      def initialize(config, options)
        @config = config
        @io = if options.key?('port')
                open_socket(options['host'] || 'localhost', options['port'].to_i)
              else
                config.out_stream
              end
        @series = SecureRandom.uuid

        current_test_case = nil

        write_event type: "start"

        config.on_event :gherkin_source_read, -> (event) {
          write_event \
          type: "source",
          uri: event.path,
          data: event.body,
          media: {
            encoding: 'utf-8',
            type: 'text/vnd.cucumber.gherkin+plain'
          }
        }

        # TODO: instead of one message, emit a series of pickle events, one for each test case (including hooks as steps)
        config.on_event :test_run_starting, -> (event) {
          write_event \
          type: "test-run-starting",
          workingDirectory: File.expand_path(Dir.pwd),
          testCases: event.test_cases.map { |test_case|
            {
              location: test_case.location,
              testSteps: test_case.test_steps.map { |test_step|
                test_step_to_json(test_step)
              }
            }
          }
        }

        config.on_event :test_case_starting, -> (event) {
          current_test_case = event.test_case # TODO: add this to the core step events so we don't have to cache it here
          write_event \
            type: "test-case-starting",
            location: event.test_case.location
        }

        config.on_event :test_step_starting, -> (event) {
          write_event \
            type: "test-step-starting",
            index: current_test_case.test_steps.index(event.test_step),
            testCase: {
              location: current_test_case.location
            }
        }

        config.on_event :test_step_finished, -> (event) {
          write_event \
            type: "test-step-finished",
            index: current_test_case.test_steps.index(event.test_step),
            testCase: {
              location: current_test_case.location
            },
            result: result_to_json(event.result)
        }

        config.on_event :test_case_finished, -> (event) {
          write_event \
            type: "test-case-finished", 
            location: event.test_case.location,
            result: result_to_json(event.result)
        }

        config.on_event :test_run_finished, -> (event) {
          @io.close if @io.is_a?(TCPSocket)
        }

      end

      private

      def result_to_json(result)
        data = {
          status: result.to_sym.to_s,
          duration: result.duration.nanoseconds
        }
        if result.respond_to?(:exception)
          data[:exception] = {
            message: result.exception.message,
            type: result.exception.class,
            stackTrace: result.exception.backtrace
          }
        end
        data
      end

      def test_step_to_json(test_step)
        if hook?(test_step)
          {
            actionLocation: test_step.action_location
          }
        else
          {
            actionLocation: test_step.action_location,
            sourceLocation: test_step.source.last.location,
          }
        end
      end

      def hook?(test_step)
        not test_step.source.last.respond_to?(:actual_keyword)
      end

      def open_socket(port, host)
        TCPSocket.new(port, host)
      end

      def write_event(attributes)
        data = attributes.merge({
          series: @series,
          timestamp: Time.now.to_i
        })
        @io.puts data.to_json
      end
    end
  end
end

