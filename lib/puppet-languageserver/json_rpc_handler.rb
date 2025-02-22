# frozen_string_literal: true

require 'json'

module PuppetLanguageServer
  CODE_INVALID_JSON       = -32700
  MSG_INVALID_JSON        = 'invalid JSON'

  CODE_INVALID_REQUEST    = -32600
  MSG_INVALID_REQ_JSONRPC = "invalid request: doesn't include \"jsonrpc\": \"2.0\""
  MSG_INVALID_REQ_ID      = 'invalid request: wrong id'
  MSG_INVALID_REQ_METHOD  = 'invalid request: wrong method'
  MSG_INVALID_REQ_PARAMS  = 'invalid request: wrong params'

  CODE_METHOD_NOT_FOUND   = -32601
  MSG_METHOD_NOT_FOUND    = 'method not found'

  CODE_INVALID_PARAMS     = -32602
  MSG_INVALID_PARAMS      = 'invalid parameter(s)'

  CODE_INTERNAL_ERROR     = -32603
  MSG_INTERNAL_ERROR      = 'internal error'

  PARSING_ERROR_RESPONSE  = '{"jsonrpc":"2.0","id":null,"error":{' \
                            "\"code\":#{CODE_INVALID_JSON}," \
                            "\"message\":\"#{MSG_INVALID_JSON}\"}}"

  BATCH_NOT_SUPPORTED_RESPONSE = '{"jsonrpc":"2.0","id":null,"error":{' \
                                  '"code":-32099,' \
                                  '"message":"batch mode not implemented"}}'

  KEY_JSONRPC   = 'jsonrpc'
  VALUE_VERSION = '2.0'
  KEY_ID        = 'id'
  KEY_METHOD    = 'method'
  KEY_PARAMS    = 'params'
  KEY_RESULT    = 'result'
  KEY_ERROR     = 'error'
  KEY_CODE      = 'code'
  KEY_MESSAGE   = 'message'

  class JSONRPCHandler < PuppetEditorServices::SimpleServerConnectionHandler
    attr_accessor :message_router

    def initialize(options = {})
      options = {} if options.nil?

      @state = :data
      @buffer = []

      @client_connection = options[:connection]
      if options[:message_router].nil?
        @message_router = PuppetLanguageServer::MessageRouter.new(options)
      else
        @message_router = options[:message_router]
      end
      @message_router.json_rpc_handler = self

      @request_sequence_id = 0
      @requests = {}
      @request_mutex = Mutex.new
    end

    # From PuppetEditorServices::SimpleServerConnectionHandler
    def post_init
      PuppetLanguageServer.log_message(:info, 'Client has connected to the language server')
    end

    # From PuppetEditorServices::SimpleServerConnectionHandler
    def unbind
      PuppetLanguageServer.log_message(:info, 'Client has disconnected from the language server')
    end

    def extract_headers(raw_header)
      header = {}
      raw_header.split("\r\n").each do |item|
        name, value = item.split(':', 2)

        if name.casecmp('Content-Length').zero?
          header['Content-Length'] = value.strip.to_i
        elsif name.casecmp('Content-Type').zero?
          header['Content-Length'] = value.strip
        else
          raise("Unknown header #{name} in Language Server message")
        end
      end
      header
    end

    # From PuppetEditorServices::SimpleServerConnectionHandler
    def receive_data(data)
      # Inspired by https://github.com/PowerShell/PowerShellEditorServices/blob/dba65155c38d3d9eeffae5f0358b5a3ad0215fac/src/PowerShellEditorServices.Protocol/MessageProtocol/MessageReader.cs
      return if data.empty?
      return if @state == :ignore

      # TODO: Thread/Atomic safe? probably not
      @buffer += data.bytes.to_a

      while @buffer.length > 4
        # Check if we have enough data for the headers
        # Need to find the first instance of '\r\n\r\n'
        offset = 0
        while offset < @buffer.length - 4
          break if @buffer[offset] == 13 && @buffer[offset + 1] == 10 && @buffer[offset + 2] == 13 && @buffer[offset + 3] == 10
          offset += 1
        end
        return unless offset < @buffer.length - 4

        # Extract the headers
        raw_header = @buffer.slice(0, offset).pack('C*').force_encoding('ASCII') # Note the headers are always ASCII encoded
        headers = extract_headers(raw_header)
        raise('Missing Content-Length header') if headers['Content-Length'].nil?

        # Now we have the headers and the content length, do we have enough data now
        minimum_buf_length = offset + 3 + headers['Content-Length'] + 1 # Need to add one as we're converting from offset (zero based) to length (1 based) arrays
        return if @buffer.length < minimum_buf_length

        # Extract the message content
        content = @buffer.slice(offset + 3 + 1, headers['Content-Length']).pack('C*').force_encoding('utf-8') # TODO: default is utf-8.  Need to enode based on Content-Type
        # Purge the buffer
        @buffer = @buffer.slice(minimum_buf_length, @buffer.length - minimum_buf_length)
        @buffer = [] if @buffer.nil?

        parse_data(content)
      end
    end

    def send_response(response)
      PuppetEditorServices.log_message(:debug, "--- OUTBOUND\n#{response}\n---")

      size = response.bytesize if response.respond_to?(:bytesize)
      @client_connection.send_data "Content-Length: #{size}\r\n\r\n" + response
    end

    def parse_data(data)
      PuppetEditorServices.log_message(:debug, "--- INBOUND\n#{data}\n---")

      result = JSON.parse(data)
      received_parsed_object(result)
    end

    # Seperate method so async JSON parsing can be supported.
    def received_parsed_object(obj)
      case obj
      # Individual request/notification.
      when Hash
        process(obj)
      # Batch: multiple requests/notifications in an array.
      # NOTE: Not implemented as it doesn't make sense using JSON RPC over pure TCP / UnixSocket.
      when Array
        send_response BATCH_NOT_SUPPORTED_RESPONSE
        close_connection_after_writing
        @state = :ignore
        batch_not_supported_error obj
      end
    end

    def process(obj)
      unless obj[KEY_JSONRPC] == '2.0'
        invalid_request obj, CODE_INVALID_REQUEST, MSG_INVALID_REQ_JSONRPC
        reply_error id, CODE_INVALID_REQUEST, MSG_INVALID_REQ_JSONRPC
        return false
      end

      # Requests must have an ID and Method
      is_request = obj.key?(KEY_ID) && obj.key?(KEY_METHOD)
      # Notifications must have a Method but no ID
      is_notification = obj.key?(KEY_METHOD) && !obj.key?(KEY_ID)
      # Responses must have an ID, no Method but one of Result or Error
      is_response = obj.key?(KEY_ID) && !obj.key?(KEY_METHOD) && (obj.key?(KEY_RESULT) || obj.key?(KEY_ERROR))

      if (params = obj[KEY_PARAMS])
        unless params.is_a?(Array) || params.is_a?(Hash)
          invalid_request obj, CODE_INVALID_REQUEST, MSG_INVALID_REQ_PARAMS
          reply_error id, CODE_INVALID_REQUEST, MSG_INVALID_REQ_PARAMS
          return false
        end
      end

      id = obj[KEY_ID]
      # Requests and Responses must have an ID that is either a string or integer
      if is_request || is_response
        unless id.is_a?(String) || id.is_a?(Integer)
          invalid_request obj, CODE_INVALID_REQUEST, MSG_INVALID_REQ_ID
          reply_error nil, CODE_INVALID_REQUEST, MSG_INVALID_REQ_ID
          return false
        end
      end

      # Requests and Notifications must have a method
      if is_request || is_notification
        unless (obj[KEY_METHOD]).is_a? String
          invalid_request obj, CODE_INVALID_REQUEST, MSG_INVALID_REQ_METHOD
          reply_error id, CODE_INVALID_REQUEST, MSG_INVALID_REQ_METHOD
          return false
        end
      end

      # Responses must have a matching request originating from this JSON Handler
      # Otherwise ignore it
      if is_response
        original_request = client_request!(obj[KEY_ID])
        return false if original_request.nil?
      end

      if is_request
        @message_router.receive_request Request.new(self, obj[KEY_ID], obj[KEY_METHOD], obj[KEY_PARAMS])
        return true
      elsif is_notification
        @message_router.receive_notification obj[KEY_METHOD], obj[KEY_PARAMS]
        return true
      elsif is_response
        @message_router.receive_response(obj, original_request)
        return true
      end
      false
    end

    def close_connection
      @client_connection.close_connection unless @client_connection.nil?
    end

    def connection_error?
      return false if @client_connection.nil?
      @client_connection.error?
    end

    def encode_json(data)
      JSON.generate(data)
    end

    def reply_error(id, code, message)
      send_response encode_json(KEY_JSONRPC => VALUE_VERSION,
                                KEY_ID      => id,
                                KEY_ERROR   => {
                                  KEY_CODE    => code,
                                  KEY_MESSAGE => message
                                })
    end

    def reply_diagnostics(uri, diagnostics)
      return nil if connection_error?

      response = {
        KEY_JSONRPC => VALUE_VERSION,
        KEY_METHOD  => 'textDocument/publishDiagnostics',
        KEY_PARAMS  => { 'uri' => uri, 'diagnostics' => diagnostics }
      }

      send_response(encode_json(response))
      true
    end

    def send_show_message_notification(msg_type, message)
      response = {
        KEY_JSONRPC => VALUE_VERSION,
        KEY_METHOD  => 'window/showMessage',
        KEY_PARAMS  => { 'type' => msg_type, 'message' => message }
      }

      send_response(encode_json(response))
      true
    end

    def send_client_request(rpc_method, params)
      req_id = client_request_id!
      request = {
        KEY_JSONRPC => VALUE_VERSION,
        KEY_ID      => req_id,
        KEY_METHOD  => rpc_method,
        KEY_PARAMS  => params
      }
      send_response(encode_json(request))
      add_client_request(req_id, request)
      req_id
    end

    # This method could be overriden in the user's inherited class.
    def parsing_error(_data, exception)
      PuppetEditorServices.log_message(:error, "parsing error:\n#{exception.message}")
    end

    # This method could be overriden in the user's inherited class.
    def batch_not_supported_error(_obj)
      PuppetEditorServices.log_message(:error, 'batch request received but not implemented')
    end

    # This method could be overriden in the user's inherited class.
    def invalid_request(_obj, code, message = nil)
      PuppetEditorServices.log_message(:error, "error #{code}: #{message}")
    end

    # Thread-safe way to get a new request id
    def client_request_id!
      value = nil
      @request_mutex.synchronize do
        value = @request_sequence_id
        @request_sequence_id += 1
      end
      value
    end

    # Stores the request so it can later be correlated with an
    # incoming repsonse
    def add_client_request(id, request)
      @request_mutex.synchronize do
        @requests[id] = request
      end
    end

    # Retrieve the request to a client. Note that this removes it
    # from the requests queue.
    def client_request!(id)
      value = nil
      @request_mutex.synchronize do
        unless @requests[id].nil?
          value = @requests[id]
          @requests.delete(id)
        end
      end
      value
    end

    class Request
      attr_reader :rpc_method, :params, :id

      def initialize(json_rpc_handler, id, rpc_method, params)
        @json_rpc_handler = json_rpc_handler
        @id = id
        @rpc_method = rpc_method
        @params = params
      end

      def reply_result(result)
        return nil if @json_rpc_handler.connection_error?

        response = {
          KEY_JSONRPC => VALUE_VERSION,
          KEY_ID      => @id,
          KEY_RESULT  => result
        }

        @json_rpc_handler.send_response(@json_rpc_handler.encode_json(response))
        true
      end

      def reply_internal_error(message = nil)
        return nil if @json_rpc_handler.connection_error?
        @json_rpc_handler.reply_error(@id, CODE_INTERNAL_ERROR, message || MSG_INTERNAL_ERROR)
      end

      def reply_method_not_found(message = nil)
        return nil if @json_rpc_handler.connection_error?
        @json_rpc_handler.reply_error(@id, CODE_METHOD_NOT_FOUND, message || MSG_METHOD_NOT_FOUND)
      end

      def reply_invalid_params(message = nil)
        return nil if @json_rpc_handler.connection_error?
        @json_rpc_handler.reply_error(@id, CODE_INVALID_PARAMS, message || MSG_INVALID_PARAMS)
      end

      def reply_custom_error(code, message)
        return nil if @json_rpc_handler.connection_error?
        unless code.is_a?(Integer) && (-32099..-32000).cover?(code) # rubocop:disable Style/IfUnlessModifier  Nicer to read like this
          raise ArgumentError, 'code must be an integer between -32099 and -32000'
        end
        @json_rpc_handler.reply_error(@id, code, message)
      end
    end
  end
end
