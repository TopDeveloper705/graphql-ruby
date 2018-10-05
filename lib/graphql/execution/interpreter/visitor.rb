# frozen_string_literal: true

module GraphQL
  module Execution
    class Interpreter
      # The visitor itself is stateless,
      # it delegates state to the `trace`
      #
      # I think it would be even better if we could somehow make
      # `continue_field` not recursive. "Trampolining" it somehow.
      class Visitor
        attr_reader :trace

        def visit(trace)
          @trace = trace
          root_operation = trace.query.selected_operation
          root_op_type = root_operation.operation_type || "query"
          legacy_root_type = trace.schema.root_type_for_operation(root_op_type)
          root_type = legacy_root_type.metadata[:type_class] || raise("Invariant: type must be class-based: #{legacy_root_type}")
          object_proxy = root_type.authorized_new(trace.query.root_value, trace.query.context)

          path = []
          evaluate_selections(path, object_proxy, root_type, root_operation.selections, root_operation_type: root_op_type)
        end

        def gather_selections(owner_type, selections, selections_by_name)
          selections.each do |node|
            case node
            when GraphQL::Language::Nodes::Field
              if passes_skip_and_include?(node)
                response_key = node.alias || node.name
                s = selections_by_name[response_key] ||= []
                s << node
              end
            when GraphQL::Language::Nodes::InlineFragment
              if passes_skip_and_include?(node)
                include_fragmment = if node.type
                  type_defn = trace.schema.types[node.type.name]
                  type_defn = type_defn.metadata[:type_class]
                  possible_types = trace.query.warden.possible_types(type_defn).map { |t| t.metadata[:type_class] }
                  possible_types.include?(owner_type)
                else
                  true
                end
                if include_fragmment
                  gather_selections(owner_type, node.selections, selections_by_name)
                end
              end
            when GraphQL::Language::Nodes::FragmentSpread
              if passes_skip_and_include?(node)
                fragment_def = trace.query.fragments[node.name]
                type_defn = trace.schema.types[fragment_def.type.name]
                type_defn = type_defn.metadata[:type_class]
                possible_types = trace.schema.possible_types(type_defn).map { |t| t.metadata[:type_class] }
                if possible_types.include?(owner_type)
                  gather_selections(owner_type, fragment_def.selections, selections_by_name)
                end
              end
            else
              raise "Invariant: unexpected selection class: #{node.class}"
            end
          end
        end

        def evaluate_selections(path, owner_object, owner_type, selections, root_operation_type: nil)
          selections_by_name = {}
          owner_type = resolve_if_late_bound_type(owner_type)
          gather_selections(owner_type, selections, selections_by_name)
          selections_by_name.each do |result_name, fields|
            ast_node = fields.first
            field_name = ast_node.name
            field_defn = owner_type.fields[field_name]
            is_introspection = false
            if field_defn.nil?
              field_defn = if owner_type == trace.schema.query.metadata[:type_class] && (entry_point_field = trace.schema.introspection_system.entry_point(name: field_name))
                is_introspection = true
                entry_point_field.metadata[:type_class]
              elsif (dynamic_field = trace.schema.introspection_system.dynamic_field(name: field_name))
                is_introspection = true
                dynamic_field.metadata[:type_class]
              else
                raise "Invariant: no field for #{owner_type}.#{field_name}"
              end
            end

            # TODO: this support is required for introspection types.
            if !field_defn.respond_to?(:extras)
              field_defn = field_defn.metadata[:type_class]
            end

            return_type = resolve_if_late_bound_type(field_defn.type)

            next_path = [*path, result_name].freeze
            # This seems janky, but we need to know
            # the field's return type at this path in order
            # to propagate `null`
            trace.set_type_at_path(next_path, return_type)

            object = owner_object

            if is_introspection
              object = field_defn.owner.authorized_new(object, trace.context)
            end

            kwarg_arguments = trace.arguments(object, field_defn, ast_node)
            # It might turn out that making arguments for every field is slow.
            # If we have to cache them, we'll need a more subtle approach here.
            if field_defn.extras.include?(:ast_node)
              kwarg_arguments[:ast_node] = ast_node
            end
            if field_defn.extras.include?(:execution_errors)
              kwarg_arguments[:execution_errors] = ExecutionErrors.new(trace.context, ast_node, next_path)
            end

            next_selections = fields.inject([]) { |memo, f| memo.concat(f.selections) }

            app_result = trace.query.trace("execute_field", {field: field_defn, path: next_path}) do
              field_defn.resolve_field_2(object, kwarg_arguments, trace.context)
            end

            # TODO can we remove this and treat it as a bounce instead?
            trace.after_lazy(app_result, field: field_defn, path: next_path, eager: root_operation_type == "mutation") do |inner_result|
              should_continue, continue_value = continue_value(next_path, inner_result, field_defn, return_type, ast_node)
              if should_continue
                continue_field(next_path, continue_value, field_defn, return_type, ast_node, next_selections)
              end
            end
          end
        end

        def continue_value(path, value, field, as_type, ast_node)
          if value.nil? || value.is_a?(GraphQL::ExecutionError)
            if value.nil?
              if as_type.non_null?
                err = GraphQL::InvalidNullError.new(field.owner, field, value)
                trace.write(path, err, propagating_nil: true)
              else
                trace.write(path, nil)
              end
            else
              value.path ||= path
              value.ast_node ||= ast_node
              trace.write(path, value, propagating_nil: as_type.non_null?)
            end
            false
          elsif value.is_a?(Array) && value.all? { |v| v.is_a?(GraphQL::ExecutionError) }
            value.each do |v|
              v.path ||= path
              v.ast_node ||= ast_node
            end
            trace.write(path, value, propagating_nil: as_type.non_null?)
            false
          elsif value.is_a?(GraphQL::UnauthorizedError)
            # this hook might raise & crash, or it might return
            # a replacement value
            next_value = begin
              trace.schema.unauthorized_object(value)
            rescue GraphQL::ExecutionError => err
              err
            end

            continue_value(path, next_value, field, as_type, ast_node)
          elsif GraphQL::Execution::Execute::SKIP == value
            false
          else
            return true, value
          end
        end

        def continue_field(path, value, field, type, ast_node, next_selections)
          type = resolve_if_late_bound_type(type)

          case type.kind
          when TypeKinds::SCALAR, TypeKinds::ENUM
            r = type.coerce_result(value, trace.query.context)
            trace.write(path, r)
          when TypeKinds::UNION, TypeKinds::INTERFACE
            resolved_type = trace.query.resolve_type(type, value)
            possible_types = trace.query.possible_types(type)

            if !possible_types.include?(resolved_type)
              parent_type = field.owner
              type_error = GraphQL::UnresolvedTypeError.new(value, field, parent_type, resolved_type, possible_types)
              trace.schema.type_error(type_error, trace.query.context)
              trace.write(path, nil, propagating_nil: field.type.non_null?)
            else
              resolved_type = resolved_type.metadata[:type_class]
              continue_field(path, value, field, resolved_type, ast_node, next_selections)
            end
          when TypeKinds::OBJECT
            object_proxy = begin
              type.authorized_new(value, trace.query.context)
            rescue GraphQL::ExecutionError => err
              err
            end
            trace.after_lazy(object_proxy, path: path, field: field) do |inner_object|
              should_continue, continue_value = continue_value(path, inner_object, field, type, ast_node)
              if should_continue
                trace.write(path, {})
                evaluate_selections(path, continue_value, type, next_selections)
              end
            end
          when TypeKinds::LIST
            trace.write(path, [])
            inner_type = type.of_type
            value.each_with_index.each do |inner_value, idx|
              next_path = [*path, idx].freeze
              trace.set_type_at_path(next_path, inner_type)
              trace.after_lazy(inner_value, path: next_path, field: field) do |inner_inner_value|
                should_continue, continue_value = continue_value(next_path, inner_inner_value, field, inner_type, ast_node)
                if should_continue
                  continue_field(next_path, continue_value, field, inner_type, ast_node, next_selections)
                end
              end
            end
          when TypeKinds::NON_NULL
            inner_type = type.of_type
            # Don't `set_type_at_path` because we want the static type,
            # we're going to use that to determine whether a `nil` should be propagated or not.
            continue_field(path, value, field, inner_type, ast_node, next_selections)
          else
            raise "Invariant: Unhandled type kind #{type.kind} (#{type})"
          end
        end

        def passes_skip_and_include?(node)
          # TODO call out to directive here
          node.directives.each do |dir|
            dir_defn = trace.schema.directives.fetch(dir.name)
            if dir.name == "skip" && trace.arguments(nil, dir_defn, dir)[:if] == true
              return false
            elsif dir.name == "include" && trace.arguments(nil, dir_defn, dir)[:if] == false
              return false
            end
          end
          true
        end

        def resolve_if_late_bound_type(type)
          if type.is_a?(GraphQL::Schema::LateBoundType)
            trace.query.warden.get_type(type.name).metadata[:type_class]
          else
            type
          end
        end
      end
    end
  end
end
