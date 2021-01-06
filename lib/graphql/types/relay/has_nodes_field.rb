# frozen_string_literal: true

module GraphQL
  module Types
    module Relay
      module HasNodesField
        def self.included(child_class)
          child_class.field(**field_options, &field_block)
        end

        class << self
          def field_options
            {
              name: "nodes",
              owner: nil,
              type: [GraphQL::Types::Relay::Node, null: true],
              null: false,
              description: "Fetches a list of objects given a list of IDs.",
              relay_nodes_field: true,
            }
          end

          def field_block
            Proc.new {
              argument :ids, "[ID!]!", required: true,
                description: "IDs of the objects."

              def resolve(obj, args, ctx)
                args[:ids].map { |id| ctx.schema.object_from_id(id, ctx) }
              end

              def resolve_field(obj, args, ctx)
                resolve(obj, args, ctx)
              end
            }
          end
        end
      end
    end
  end
end
