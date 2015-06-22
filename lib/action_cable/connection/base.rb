module ActionCable
  module Connection
    class Base
      include Identification
      include InternalChannel

      attr_reader :server, :env
      delegate :worker_pool, :pubsub, to: :server

      attr_reader :logger

      def initialize(server, env)
        @started_at = Time.now

        @server, @env = server, env

        @logger = TaggedLoggerProxy.new(server.logger, tags: log_tags)

        @heartbeat      = ActionCable::Connection::Heartbeat.new(self)
        @subscriptions  = ActionCable::Connection::Subscriptions.new(self)
        @message_buffer = ActionCable::Connection::MessageBuffer.new(self)
      end

      def process
        logger.info started_request_message

        if websocket?
          @websocket = Faye::WebSocket.new(@env)

          websocket.on(:open)    { |event| send_async :on_open   }
          websocket.on(:message) { |event| on_message event.data }
          websocket.on(:close)   { |event| send_async :on_close  }
          
          websocket.rack_response
        else
          respond_to_invalid_request
        end
      end

      def receive(data_in_json)
        if websocket_alive?
          data = decode_json data_in_json

          case data['command']
          when 'subscribe'   then subscriptions.add data
          when 'unsubscribe' then subscriptions.remove data
          when 'message'     then process_message data
          else
            logger.error "Received unrecognized command in #{data.inspect}"
          end
        else
          logger.error "Received data without a live websocket (#{data.inspect})"
        end
      end

      def transmit(data)
        websocket.send data
      end

      def close
        logger.error "Closing connection"
        websocket.close
      end


      def send_async(method, *arguments)
        worker_pool.async.invoke(self, method, *arguments)
      end

      def statistics
        {
          identifier:    connection_identifier,
          started_at:    @started_at,
          subscriptions: subscriptions.identifiers
        }
      end


      protected
        def request
          @request ||= ActionDispatch::Request.new(Rails.application.env_config.merge(env))
        end

        def cookies
          request.cookie_jar
        end


      private
        attr_reader :websocket
        attr_reader :heartbeat, :subscriptions, :message_buffer

        def on_open
          server.add_connection(self)

          connect if respond_to?(:connect)
          subscribe_to_internal_channel
          heartbeat.start

          message_buffer.process!
        end

        def on_message(message)
          message_buffer.append message
        end

        def on_close
          logger.info finished_request_message

          server.remove_connection(self)

          subscriptions.cleanup
          unsubscribe_from_internal_channel
          heartbeat.stop

          disconnect if respond_to?(:disconnect)
        end


        def process_message(message)
          subscriptions.find(message['identifier']).perform_action decode_json(message['data'])
        rescue Exception => e
          logger.error "Could not process message (#{message.inspect})"
          log_exception(e)
        end


        def decode_json(json)
          ActiveSupport::JSON.decode json
        end

        def respond_to_invalid_request
          logger.info finished_request_message
          [ 404, { 'Content-Type' => 'text/plain' }, [ 'Page not found' ] ]
        end

        def websocket_alive?
          websocket && websocket.ready_state == Faye::WebSocket::API::OPEN
        end

        def websocket?
          @is_websocket ||= Faye::WebSocket.websocket?(@env)
        end

        def started_request_message
          'Started %s "%s"%s for %s at %s' % [
            request.request_method,
            request.filtered_path,
            websocket? ? ' [Websocket]' : '',
            request.ip,
            Time.now.to_default_s ]
        end

        def finished_request_message
          'Finished "%s"%s for %s at %s' % [
            request.filtered_path,
            websocket? ? ' [Websocket]' : '',
            request.ip,
            Time.now.to_default_s ]
        end

        def log_exception(e)
          logger.error "There was an exception: #{e.class} - #{e.message}"
          logger.error e.backtrace.join("\n")
        end

        def log_tags
          server.log_tags.map { |tag| tag.respond_to?(:call) ? tag.call(request) : tag.to_s.camelize }
        end
    end
  end
end
