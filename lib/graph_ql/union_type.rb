# A collection of {ObjectType}s
#
# @example a union of types
#   PetUnion = GraphQL::UnionType.new("Pet", "House pets", [DogType, CatType])
#
class GraphQL::UnionType
  include GraphQL::DefinitionHelpers::NonNullWithBang
  include GraphQL::DefinitionHelpers::DefinedByConfig
  attr_accessor :name, :description, :possible_types

  class DefinitionConfig
    extend GraphQL::DefinitionHelpers::Definable
    attr_definable :name, :description, :possible_types

    def to_instance
      object = GraphQL::UnionType.new
      object.name = name
      object.description = description
      object.possible_types = possible_types
      object
    end
  end

  def initialize(name = nil, desc = nil, types = nil)
    @name = name
    @description = desc
    @possible_types = types
    name && warn("Initializing with .new is deprecated, use .define instead! (see #{self})")
  end

  def kind
    GraphQL::TypeKinds::UNION
  end

  # @see {InterfaceType#resolve_type}
  def resolve_type(object)
    type_name = object.class.name
    possible_types.find {|t| t.name == type_name}
  end
end
