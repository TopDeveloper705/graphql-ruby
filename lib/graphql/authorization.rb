# frozen_string_literal: true
module GraphQL
  module Authorization
    class InaccessibleFieldsError < GraphQL::AnalysisError
      # @return [Array<Schema::Field, GraphQL::Field>] Fields that failed `.accessible?` checks
      attr_reader :fields

      # @return [GraphQL::Query::Context] The current query's context
      attr_reader :context

      # @return [Array<GraphQL::InternalRepresentation::Node>] The visited nodes that failed `.accessible?` checks
      # @see {#fields} for the Field definitions
      attr_reader :irep_nodes

      def initialize(fields:, irep_nodes:, context:)
        @fields = fields
        @irep_nodes = irep_nodes
        @context = context
        super("Some fields in this query are not accessible: #{fields.map(&:graphql_name).join(", ")}")
      end
    end

    module Analyzer
      module_function
      def initial_value(query)
        {
          schema: query.schema,
          context: query.context,
          inaccessible_nodes: [],
        }
      end

      def call(memo, visit_type, irep_node)
        if visit_type == :enter
          field = irep_node.definition
          if field
            schema = memo[:schema]
            ctx = memo[:context]
            next_field_accessible = schema.accessible?(field, ctx)
            if !next_field_accessible
              memo[:inaccessible_nodes] << irep_node
            else
              arg_accessible = true
              irep_node.arguments.argument_values.each do |name, arg_value|
                arg_accessible = schema.accessible?(arg_value.definition, ctx)
                if !arg_accessible
                  memo[:inaccessible_nodes] << irep_node
                  break
                end
              end
              if arg_accessible
                return_type = field.type.unwrap
                next_type_accessible = schema.accessible?(return_type, ctx)
                if !next_type_accessible
                  memo[:inaccessible_nodes] << irep_node
                end
              end
            end
          end
        end
        memo
      end

      def final_value(memo)
        nodes = memo[:inaccessible_nodes]
        if nodes.any?
          fields = nodes.map do |node|
            field_inst = node.definition
            # Get the "source of truth" for this field
            field_inst.metadata[:type_class] || field_inst
          end
          context = memo[:context]
          err = InaccessibleFieldsError.new(fields: fields, irep_nodes: nodes, context: context)
          context.schema.inaccessible_fields(err)
        else
          nil
        end
      end
    end

    class AstAnalyzer < GraphQL::Analysis::AST::Analyzer
      class InaccessibleFieldsError < ::GraphQL::AnalysisError
        # @return [Array<Schema::Field, GraphQL::Field>] Fields that failed `.accessible?` checks
        attr_reader :fields

        # @return [GraphQL::Query::Context] The current query's context
        attr_reader :context

        # @return [Array<GraphQL::Language::Node>] The visited nodes that failed `.accessible?` checks
        # @see {#fields} for the Field definitions
        attr_reader :nodes

        def initialize(fields:, nodes:, context:)
          @fields = fields
          @nodes = nodes
          @context = context
          super("Some fields in this query are not accessible: #{fields.map(&:graphql_name).join(", ")}")
        end
      end

      def initialize(query)
        super
        @inaccessible_nodes = []
        @schema = query.schema
        @ctx = query.context
      end

      def on_enter_field(node, parent, visitor)
        field_defn = visitor.field_definition
        next_field_accessible = accessible?(field_defn)

        if !next_field_accessible
          @inaccessible_nodes << [node, field_defn]
        else
          arg_accessible = true
          argument_defns(node, field_defn).each do |arg_defn|
            arg_accessible = accessible?(arg_defn)
            if !arg_accessible
              @inaccessible_nodes << [node, field_defn]
              break
            end
          end
          if arg_accessible
            return_type = visitor.type_definition
            next_type_accessible = accessible?(return_type)
            if !next_type_accessible
              @inaccessible_nodes << [node, field_defn]
            end
          end
        end
      end

      def result
        if @inaccessible_nodes.any?
          nodes, fields = @inaccessible_nodes.transpose
          err = InaccessibleFieldsError.new(fields: fields, nodes: nodes, context: @context)
          @schema.inaccessible_fields(err)
        end
      end

      private

      def argument_defns(node, field_defn)
        node.arguments.map do |arg|
          field_defn.arguments[arg.name]
        end
      end

      def accessible?(member)
        @schema.accessible?(member, @ctx)
      end
    end
  end
end
