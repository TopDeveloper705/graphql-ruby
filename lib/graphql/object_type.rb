# frozen_string_literal: true
module GraphQL
  # @api deprecated
  class ObjectType < GraphQL::BaseType
    accepts_definitions :interfaces, :fields, :mutation, :relay_node_type, field: GraphQL::Define::AssignObjectField
    accepts_definitions implements: ->(type, *interfaces, inherit: false) { type.implements(interfaces, inherit: inherit) }

    attr_accessor :fields, :mutation, :relay_node_type
    ensure_defined(:fields, :mutation, :interfaces, :relay_node_type)

    # @!attribute fields
    #   @return [Hash<String => GraphQL::Field>] Map String fieldnames to their {GraphQL::Field} implementations

    # @!attribute mutation
    #   @return [GraphQL::Relay::Mutation, nil] The mutation this object type was derived from, if it is an auto-generated payload type.

    def initialize
      super
      @fields = {}
      @interface_fields = {}
      @interface_type_memberships = []
      @inherited_interface_type_memberships = []
    end

    def initialize_copy(other)
      super
      @interface_type_memberships = other.interface_type_memberships.dup
      @inherited_interface_type_memberships = other.inherited_interface_type_memberships.dup
      @fields = other.fields.dup
    end

    # This method declares interfaces for this type AND inherits any field definitions
    # @param new_interfaces [Array<GraphQL::Interface>] interfaces that this type implements
    # @deprecated Use `implements` instead of `interfaces`.
    def interfaces=(new_interfaces)
      @interface_type_memberships = []
      @inherited_interface_type_memberships = []
      @dirty_inherited_fields = {}
      @clean_inherited_fields = nil
      implements(new_interfaces, inherit: true)
    end

    def interfaces(ctx = GraphQL::Query::NullContext)
      ifaces, inherited_ifaces = load_interfaces(ctx)
      ifaces + inherited_ifaces
    end

    def kind
      GraphQL::TypeKinds::OBJECT
    end

    # This fields doesnt have instrumenation applied
    # @see [Schema#get_field] Get field with instrumentation
    # @return [GraphQL::Field] The field definition for `field_name` (may be inherited from interfaces)
    def get_field(field_name)
      fields[field_name] || interface_fields[field_name]
    end

    # These fields don't have instrumenation applied
    # @see [Schema#get_fields] Get fields with instrumentation
    # @return [Array<GraphQL::Field>] All fields, including ones inherited from interfaces
    def all_fields
      interface_fields.merge(self.fields).values
    end

    # Declare that this object implements this interface.
    # This declaration will be validated when the schema is defined.
    # @param interfaces [Array<GraphQL::Interface>] add a new interface that this type implements
    # @param inherits [Boolean] If true, copy the interfaces' field definitions to this type
    def implements(interfaces, inherit: false, **options)
      if !interfaces.is_a?(Array)
        raise ArgumentError, "`implements(interfaces)` must be an array, not #{interfaces.class} (#{interfaces})"
      end
      @clean_inherited_fields = nil

      type_memberships = inherit ? @inherited_interface_type_memberships : @interface_type_memberships
      type_memberships_from_interfaces = interfaces.map do |iface|
        # this needs to be fixed
        # For some reason, ifaces were being read as procs
        # This was coming from interfaces being built by definition
        if iface.respond_to?(:type_membership_class)
          iface.type_membership_class.new(iface, self, options)
        else
          GraphQL::Schema::TypeMembership.new(iface, self, options)
        end
      end
      type_memberships.concat(type_memberships_from_interfaces)
    end

    def resolve_type_proc
      nil
    end

    def interface_type_memberships=(interface_type_memberships)
      @interface_type_memberships = interface_type_memberships
    end

    protected

    attr_reader :interface_type_memberships, :inherited_interface_type_memberships

    private

    def normalize_interfaces(ifaces)
      ifaces.map { |i_type| GraphQL::BaseType.resolve_related_type(i_type) }
    end

    def interface_fields
      if @clean_inherited_fields
        @clean_inherited_fields
      else
        _ifaces, inherited_ifaces = load_interfaces(nil)
        @clean_inherited_fields = {}
        inherited_ifaces.each do |iface|
          if iface.is_a?(GraphQL::InterfaceType)
            @clean_inherited_fields.merge!(iface.fields)
          end
        end
        @clean_inherited_fields
      end
    end

    def load_interfaces(ctx = GraphQL::Query::NullContext)
      ensure_defined
      clean_ifaces = []
      clean_inherited_ifaces = []
      @interface_type_memberships.each do |type_membership|
        if ctx.nil? || type_membership.visible?(ctx)
          clean_ifaces << GraphQL::BaseType.resolve_related_type(type_membership.abstract_type)
        end
      end

      @inherited_interface_type_memberships.each do |type_membership|
        if ctx.nil? || type_membership.visible?(ctx)
          clean_inherited_ifaces << GraphQL::BaseType.resolve_related_type(type_membership.abstract_type)
        end
      end

      [clean_ifaces, clean_inherited_ifaces]
    end
  end
end
