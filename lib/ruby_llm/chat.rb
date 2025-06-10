# frozen_string_literal: true

module RubyLLM
  # Represents a conversation with an AI model. Handles message history,
  # streaming responses, and tool integration with a simple, conversational API.
  #
  # Example:
  #   chat = RubyLLM.chat
  #   chat.ask "What's the best way to learn Ruby?"
  #   chat.ask "Can you elaborate on that?"
  class Chat
    include Enumerable

    attr_reader :model, :messages, :tools

    def initialize(model: nil, provider: nil, assume_model_exists: false, context: nil)
      if assume_model_exists && !provider
        raise ArgumentError, 'Provider must be specified if assume_model_exists is true'
      end

      @context = context
      @config = context&.config || RubyLLM.config
      model_id = model || @config.default_model
      with_model(model_id, provider: provider, assume_exists: assume_model_exists)
      @temperature = 0.7
      @messages = []
      @tools = {}
      @on = {
        new_message: nil,
        end_message: nil
      }
    end

    def ask(message = nil, with: nil, &)
      add_message role: :user, content: Content.new(message, with)
      complete(&)
    end

    alias say ask

    def with_instructions(instructions, replace: false)
      @messages = @messages.reject { |msg| msg.role == :system } if replace

      add_message role: :system, content: instructions
      self
    end

    def with_tool(tool)
      unless @model.supports_functions?
        raise UnsupportedFunctionsError, "Model #{@model.id} doesn't support function calling"
      end

      tool_instance = tool.is_a?(Class) ? tool.new : tool
      @tools[tool_instance.name.to_sym] = tool_instance
      self
    end

    def with_tools(*tools)
      tools.each { |tool| with_tool tool }
      self
    end

    def with_model(model_id, provider: nil, assume_exists: false)
      @model, @provider = Models.resolve(model_id, provider:, assume_exists:)
      @connection = @context ? @context.connection_for(@provider) : @provider.connection(@config)
      self
    end

    def with_temperature(temperature)
      @temperature = temperature
      self
    end

    def with_thinking_budget(thinking_budget)
      @thinking_budget = thinking_budget
      self
    end

    def with_context(context)
      @context = context
      @config = context.config
      with_model(@model.id, provider: @provider.slug, assume_exists: true)
      self
    end

    def on_new_message(&block)
      @on[:new_message] = block
      self
    end

    def on_end_message(&block)
      @on[:end_message] = block
      self
    end

    def each(&)
      messages.each(&)
    end

    def complete(&)
      @on[:new_message]&.call
      response = @provider.complete(
        messages,
        tools: @tools,
        temperature: @temperature,
        model: @model.id,
        connection: @connection,
        thinking_budget: @thinking_budget,
        &
      )
      @on[:end_message]&.call(response)

      add_message response
      if response.tool_call?
        handle_tool_calls(response, &)
      else
        response
      end
    end

    def add_message(message_or_attributes)
      message = message_or_attributes.is_a?(Message) ? message_or_attributes : Message.new(message_or_attributes)
      messages << message
      message
    end

    def reset_messages!
      @messages.clear
    end

    private

    def handle_tool_calls(response, &)
      response.tool_calls.each_value do |tool_call|
        @on[:new_message]&.call
        result = execute_tool tool_call
        message = add_tool_result tool_call.id, result
        @on[:end_message]&.call(message)
      end

      complete(&)
    end

    def execute_tool(tool_call)
      tool = tools[tool_call.name.to_sym]
      args = tool_call.arguments
      tool.call(args)
    end

    def add_tool_result(tool_use_id, result)
      add_message(
        role: :tool,
        content: result.is_a?(Hash) && result[:error] ? result[:error] : result.to_s,
        tool_call_id: tool_use_id
      )
    end
  end
end
