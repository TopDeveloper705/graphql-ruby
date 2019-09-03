# frozen_string_literal: true
require "securerandom"
require "graphql/subscriptions/event"
require "graphql/subscriptions/instrumentation"
require "graphql/subscriptions/serialize"
if defined?(ActionCable)
  require "graphql/subscriptions/action_cable_subscriptions"
end
require "graphql/subscriptions/subscription_root"

module GraphQL
  class Subscriptions
    # Raised when either:
    # - the triggered `event_name` doesn't match a field in the schema; or
    # - one or more arguments don't match the field arguments
    class InvalidTriggerError < GraphQL::Error
    end

    # @see {Subscriptions#initialize} for options, concrete implementations may add options.
    def self.use(defn, options = {})
      if defn.is_a?(Class)
        schema = defn
        instrumentation = Subscriptions::Instrumentation.new(schema: schema)
        schema.instrument(:query, instrumentation)
        # This will be applied if the legacy runtime is used
        schema.instrument(:field, instrumentation)
      else
        schema = defn.target
        if schema.subscriptions
          # already attached to the class
          return
        end
        instrumentation = Subscriptions::Instrumentation.new(schema: schema)
        defn.instrument(:field, instrumentation)
        defn.instrument(:query, instrumentation)
      end

      options[:schema] = schema
      schema.subscriptions = self.new(options)
      nil
    end

    # @param schema [Class] the GraphQL schema this manager belongs to
    def initialize(schema:, **rest)
      @schema = schema
    end

    # Fetch subscriptions matching this field + arguments pair
    # And pass them off to the queue.
    # @param event_name [String]
    # @param args [Hash<String, Symbol => Object]
    # @param object [Object]
    # @param scope [Symbol, String]
    # @return [void]
    def trigger(event_name, args, object, scope: nil)
      event_name = event_name.to_s

      # Try with the verbatim input first:
      field = @schema.get_field(@schema.subscription, event_name)

      if field.nil?
        # And if it wasn't found, normalize it:
        normalized_event_name = normalize_name(event_name)
        field = @schema.get_field(@schema.subscription, normalized_event_name)
        if field.nil?
          raise InvalidTriggerError, "No subscription matching trigger: #{event_name} (looked for #{@schema.subscription.graphql_name}.#{normalized_event_name})"
        end
      else
        # Since we found a field, the original input was already normalized
        normalized_event_name = event_name
      end

      # Normalize symbol-keyed args to strings, try camelizing them
      normalized_args = normalize_arguments(normalized_event_name, field, args)

      event = Subscriptions::Event.new(
        name: normalized_event_name,
        arguments: normalized_args,
        field: field,
        scope: scope,
      )
      execute_all(event, object)
    end

    # `event` was triggered on `object`, and `subscription_id` was subscribed,
    # so it should be updated.
    #
    # Load `subscription_id`'s GraphQL data, re-evaluate the query, and deliver the result.
    #
    # This is where a queue may be inserted to push updates in the background.
    #
    # @param subscription_id [String]
    # @param event [GraphQL::Subscriptions::Event] The event which was triggered
    # @param object [Object] The value for the subscription field
    # @return [void]
    def execute(subscription_id, event, object)
      # Lookup the saved data for this subscription
      query_data = read_subscription(subscription_id)
      # Fetch the required keys from the saved data
      query_string = query_data.fetch(:query_string)
      variables = query_data.fetch(:variables)
      context = query_data.fetch(:context)
      operation_name = query_data.fetch(:operation_name)
      # Re-evaluate the saved query
      result = @schema.execute(
        {
          query: query_string,
          context: context,
          subscription_topic: event.topic,
          operation_name: operation_name,
          variables: variables,
          root_value: object,
        }
      )
      deliver(subscription_id, result)
    rescue GraphQL::Schema::Subscription::NoUpdateError
      # This update was skipped in user code; do nothing.
    rescue GraphQL::Schema::Subscription::UnsubscribedError
      # `unsubscribe` was called, clean up on our side
      # TODO also send `{more: false}` to client?
      delete_subscription(subscription_id)
    end

    # Event `event` occurred on `object`,
    # Update all subscribers.
    # @param event [Subscriptions::Event]
    # @param object [Object]
    # @return [void]
    def execute_all(event, object)
      each_subscription_id(event) do |subscription_id|
        execute(subscription_id, event, object)
      end
    end

    # Get each `subscription_id` subscribed to `event.topic` and yield them
    # @param event [GraphQL::Subscriptions::Event]
    # @yieldparam subscription_id [String]
    # @return [void]
    def each_subscription_id(event)
      raise NotImplementedError
    end

    # The system wants to send an update to this subscription.
    # Read its data and return it.
    # @param subscription_id [String]
    # @return [Hash] Containing required keys
    def read_subscription(subscription_id)
      raise NotImplementedError
    end

    # A subscription query was re-evaluated, returning `result`.
    # The result should be send to `subscription_id`.
    # @param subscription_id [String]
    # @param result [Hash]
    # @return [void]
    def deliver(subscription_id, result)
      raise NotImplementedError
    end

    # `query` was executed and found subscriptions to `events`.
    # Update the database to reflect this new state.
    # @param query [GraphQL::Query]
    # @param events [Array<GraphQL::Subscriptions::Event>]
    # @return [void]
    def write_subscription(query, events)
      raise NotImplementedError
    end

    # A subscription was terminated server-side.
    # Clean up the database.
    # @param subscription_id [String]
    # @return void.
    def delete_subscription(subscription_id)
      raise NotImplementedError
    end

    # @return [String] A new unique identifier for a subscription
    def build_id
      SecureRandom.uuid
    end

    # Convert a user-provided event name or argument
    # to the equivalent in GraphQL.
    #
    # By default, it converts the identifier to camelcase.
    # Override this in a subclass to change the transformation.
    #
    # @param event_or_arg_name [String, Symbol]
    # @return [String]
    def normalize_name(event_or_arg_name)
      Schema::Member::BuildType.camelize(event_or_arg_name.to_s)
    end

    private

    # Recursively normalize `args` as belonging to `arg_owner`:
    # - convert symbols to strings,
    # - if needed, camelize the string (using {#normalize_name})
    # @param arg_owner [GraphQL::Field, GraphQL::BaseType]
    # @param args [Hash, Array, Any] some GraphQL input value to coerce as `arg_owner`
    # @return [Any] normalized arguments value
    def normalize_arguments(event_name, arg_owner, args)
      case arg_owner
      when GraphQL::Field, GraphQL::InputObjectType, GraphQL::Schema::Field, Class
        if arg_owner.is_a?(Class) && !arg_owner.kind.input_object?
          # it's a type, but not an input object
          return args
        end
        normalized_args = {}
        missing_arg_names = []
        args.each do |k, v|
          arg_name = k.to_s
          arg_defn = arg_owner.arguments[arg_name]
          if arg_defn
            normalized_arg_name = arg_name
          else
            normalized_arg_name = normalize_name(arg_name)
            arg_defn = arg_owner.arguments[normalized_arg_name]
          end

          if arg_defn
            # TODO will this break compatibility with existing subscriptions?
            # It changes the topic
            if arg_defn.keyword
              normalized_arg_name = arg_defn.keyword.to_s
            end
            normalized_args[normalized_arg_name] = normalize_arguments(event_name, arg_defn.type, v)
          else
            # Couldn't find a matching argument definition
            missing_arg_names << arg_name
          end
        end

        # Backfill default values so that trigger arguments
        # match query arguments.
        arg_owner.arguments.each do |name, arg_defn|
          if arg_defn.default_value? && !normalized_args.key?(arg_defn.name)
            normalized_args[arg_defn.name] = arg_defn.default_value
          end
        end

        if missing_arg_names.any?
          arg_owner_name = if arg_owner.is_a?(GraphQL::Field)
            "Subscription.#{arg_owner.name}"
          elsif arg_owner.is_a?(GraphQL::Schema::Field)
            arg_owner.path
          elsif arg_owner.is_a?(Class)
            arg_owner.graphql_name
          else
            arg_owner.to_s
          end
          raise InvalidTriggerError, "Can't trigger Subscription.#{event_name}, received undefined arguments: #{missing_arg_names.join(", ")}. (Should match arguments of #{arg_owner_name}.)"
        end

        normalized_args
      when GraphQL::ListType, GraphQL::Schema::List
        args.map { |a| normalize_arguments(event_name, arg_owner.of_type, a) }
      when GraphQL::NonNullType, GraphQL::Schema::NonNull
        normalize_arguments(event_name, arg_owner.of_type, args)
      else
        args
      end
    end
  end
end
