# frozen_string_literal: true
module LazyHelpers
  class Wrapper
    def initialize(item = nil, &block)
      if block
        @block = block
      else
        @item = item
      end
    end

    def item
      if @block
        @item = @block.call()
        @block = nil
      end
      @item
    end
  end

  class SumAll
    attr_reader :own_value
    attr_writer :value

    def initialize(own_value)
      @own_value = own_value
      all << self
    end

    def value
      @value ||= begin
        total_value = all.map(&:own_value).reduce(&:+)
        all.each { |v| v.value = total_value}
        all.clear
        total_value
      end
      @value
    end

    def all
      self.class.all
    end

    def self.all
      @all ||= []
    end
  end

  class LazySum < GraphQL::Schema::Object
    field :value, Integer, null: true
    def value
      object == 13 ? nil : object
    end

    field :nestedSum, LazySum, null: false do
      argument :value, Integer, required: true
    end

    def nested_sum(value:)
      if value == 13
        Wrapper.new(nil)
      else
        SumAll.new(@object + value)
      end
    end

    field :nullableNestedSum, LazySum, null: true do
      argument :value, Integer, required: true
    end
    alias :nullable_nested_sum :nested_sum
  end

  using GraphQL::DeprecatedDSL
  if RUBY_ENGINE == "jruby"
    # JRuby doesn't support refinements, so the `using` above won't work
    GraphQL::DeprecatedDSL.activate
  end

  class LazyQuery < GraphQL::Schema::Object
    field :int, Integer, null: false do
      argument :value, Integer, required: true
      argument :plus, Integer, required: false, default_value: 0
    end
    def int(value:, plus:)
      Wrapper.new(value + plus)
    end

    field :nested_sum, LazySum, null: false do
      argument :value, Integer, required: true
    end

    def nested_sum(value:)
      SumAll.new(value)
    end

    field :nullable_nested_sum, LazySum, null: true do
      argument :value, Integer, required: true
    end

    def nullable_nested_sum(value:)
      if value == 13
        Wrapper.new { raise GraphQL::ExecutionError.new("13 is unlucky") }
      else
        SumAll.new(value)
      end
    end

    field :list_sum, [LazySum], null: true do
      argument :values, [Integer], required: true
    end
    def list_sum(values:)
      values
    end
  end

  class SumAllInstrumentation
    def initialize(counter:)
      @counter = counter
    end

    def before_query(q)
      add_check(q, "before #{q.selected_operation.name}")
      # TODO not threadsafe
      # This should use multiplex-level context
      SumAll.all.clear
    end

    def after_query(q)
      add_check(q, "after #{q.selected_operation.name}")
    end

    def before_multiplex(multiplex)
      add_check(multiplex, "before multiplex #@counter")
    end

    def after_multiplex(multiplex)
      add_check(multiplex, "after multiplex #@counter")
    end

    def add_check(obj, text)
      checks = obj.context[:instrumentation_checks]
      if checks
        checks << text
      end
    end
  end

  class LazySchema < GraphQL::Schema
    query(LazyQuery)
    mutation(LazyQuery)
    lazy_resolve(Wrapper, :item)
    lazy_resolve(SumAll, :value)
    instrument(:query, SumAllInstrumentation.new(counter: nil))
    instrument(:multiplex, SumAllInstrumentation.new(counter: 1))
    instrument(:multiplex, SumAllInstrumentation.new(counter: 2))

    if TESTING_INTERPRETER
      use GraphQL::Execution::Interpreter
    end

    def self.sync_lazy(lazy)
      if lazy.is_a?(SumAll) && lazy.own_value > 1000
        lazy.value # clear the previous set
        lazy.own_value - 900
      else
        super
      end
    end
  end

  def run_query(query_str)
    LazySchema.execute(query_str)
  end
end
