module GraphQL
  class Query
    class Executor
      class OperationNameMissingError < StandardError
        def initialize(names)
          msg = "You must provide an operation name from: #{names.join(", ")}"
          super(msg)
        end
      end

      attr_reader :query, :operation_name
      def initialize(query, operation_name)
        @query = query
        @operation_name = operation_name
      end

      def result
        return {} if query.operations.none?
        operation = find_operation(operation_name, query.operations)
        if operation.operation_type == "query"
          root = query.schema.query
        elsif operation.operation_type == "mutation"
          root = query.schema.mutation
        end
        resolver = GraphQL::Query::OperationResolver.new(operation, root, query)
        resolver.result
      end

      private

      def find_operation(operation_name, operations)
        if operations.length == 1
          operations.values.first
        elsif !operations.key?(operation_name)
          raise OperationNameMissingError, operations.keys
        else
          operations[operation_name]
        end
      end
    end
  end
end
