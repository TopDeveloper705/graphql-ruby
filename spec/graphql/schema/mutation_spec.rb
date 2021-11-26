# frozen_string_literal: true
require "spec_helper"

describe GraphQL::Schema::Mutation do
  let(:mutation) { Jazz::AddInstrument }
  after do
    Jazz::Models.reset
  end

  it "Doesn't override !" do
    assert_equal false, !mutation
  end

  describe "definition" do
    it "passes along description" do
      assert_equal "Register a new musical instrument in the database", mutation.field_options[:description]
      assert_equal "Autogenerated return type of AddInstrument", mutation.payload_type.description
    end
  end

  describe "argument prepare" do
    it "calls methods on the mutation, uses `as:`" do
      query_str = "mutation { prepareInput(input: 4) }"
      res = Jazz::Schema.execute(query_str)
      assert_equal 16, res["data"]["prepareInput"], "It's squared by the prepare method"
    end
  end

  describe "a derived field" do
    it "has a reference to the mutation" do
      f = GraphQL::Schema::Field.from_options(name: "x", **mutation.field_options)
      assert_equal mutation, f.mutation

      # Make sure it's also present in the schema
      f2 = Jazz::Schema.find("Mutation.addInstrument")
      assert_equal mutation, f2.mutation
    end
  end

  describe ".payload_type" do
    it "has a reference to the mutation" do
      assert_equal mutation, mutation.payload_type.mutation
    end
  end

  describe ".field" do
    it "raises a nice error when called without args" do
      err = assert_raises(ArgumentError) { mutation.field }
      assert_includes err.message, "Use `mutation: Jazz::AddInstrument` to attach this mutation instead."
    end
  end

  describe ".object_class" do
    it "can override & inherit the parent class" do
      obj_class = Class.new(GraphQL::Schema::Object)
      mutation_class = Class.new(GraphQL::Schema::Mutation) do
        object_class(obj_class)
      end
      mutation_subclass = Class.new(mutation_class)

      assert_equal(GraphQL::Schema::Object, GraphQL::Schema::Mutation.object_class)
      assert_equal(obj_class, mutation_class.object_class)
      assert_equal(obj_class, mutation_subclass.object_class)
    end
  end

  describe ".argument_class" do
    it "can override & inherit the parent class" do
      arg_class = Class.new(GraphQL::Schema::Argument)
      mutation_class = Class.new(GraphQL::Schema::Mutation) do
        argument_class(arg_class)
      end

      mutation_subclass = Class.new(mutation_class)

      assert_equal(GraphQL::Schema::Argument, GraphQL::Schema::Mutation.argument_class)
      assert_equal(arg_class, mutation_class.argument_class)
      assert_equal(arg_class, mutation_subclass.argument_class)
    end
  end

  describe "evaluation" do
    it "runs mutations" do
      query_str = <<-GRAPHQL
      mutation {
        addInstrument(name: "Trombone", family: BRASS) {
          instrument {
            name
            family
          }
          entries {
            name
          }
          ee
        }
      }
      GRAPHQL

      response = Jazz::Schema.execute(query_str)
      assert_equal "Trombone", response["data"]["addInstrument"]["instrument"]["name"]
      assert_equal "BRASS", response["data"]["addInstrument"]["instrument"]["family"]
      errors_class = "GraphQL::Execution::Interpreter::ExecutionErrors"
      assert_equal errors_class, response["data"]["addInstrument"]["ee"]
      assert_equal 7, response["data"]["addInstrument"]["entries"].size
    end

    it "accepts a list of errors as a valid result" do
      query_str = "mutation { returnsMultipleErrors { dummyField { name } } }"

      response = Jazz::Schema.execute(query_str)
      assert_equal 2, response["errors"].length, "It should return two errors"
    end

    it "raises a mutation-specific invalid null error" do
      query_str = "mutation { returnInvalidNull { int } }"
      response = Jazz::Schema.execute(query_str)
      assert_equal ["Cannot return null for non-nullable field ReturnInvalidNullPayload.int"], response["errors"].map { |e| e["message"] }
      if TESTING_INTERPRETER
        error = response.query.context.errors.first
        assert_instance_of Jazz::ReturnInvalidNull.payload_type::InvalidNullError, error
        assert_equal "Jazz::ReturnInvalidNull::ReturnInvalidNullPayload::InvalidNullError", error.class.inspect
      end
    end
  end

  describe ".null" do
    it "overrides whether or not the field can be null" do
      non_nullable_mutation_class = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Thing1"
        null(false)
      end

      nullable_mutation_class = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Thing2"
        null(true)
      end

      default_mutation_class = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Thing3"
      end

      assert default_mutation_class.field_options[:null]
      assert nullable_mutation_class.field_options[:null]
      refute non_nullable_mutation_class.field_options[:null]
    end

    it "should inherit and override in subclasses" do
      base_mutation = Class.new(GraphQL::Schema::Mutation) do
        null(false)
      end

      inheriting_mutation = Class.new(base_mutation) do
        graphql_name "Thing"
      end

      override_mutation = Class.new(base_mutation) do
        graphql_name "Thing2"
        null(true)
      end

      assert_equal false, inheriting_mutation.field_options[:null]
      assert override_mutation.field_options[:null]
    end
  end

  it "warns once for possible conflict methods" do
    expected_warning = "X's `field :module` conflicts with a built-in method, use `hash_key:` or `method:` to pick a different resolve behavior for this field (for example, `hash_key: :module_value`, and modify the return hash). Or use `method_conflict_warning: false` to suppress this warning.\n"
    assert_output "", expected_warning do
      # This should warn:
      mutation = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "X"
        field :module, String
      end
      # This should not warn again, when generating the payload type with the same fields:
      mutation.payload_type
    end

    assert_output "", "" do
      mutation = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "X"
        field :module, String, hash_key: :module_value
      end
      mutation.payload_type
    end
  end

  class InterfaceMutationSchema < GraphQL::Schema
    class SignIn < GraphQL::Schema::Mutation
      argument :login, String
      argument :password, String
      field :success, Boolean, null: false
      def resolve(login:, password:)
        { success: login == password }
      end
    end

    module Auth
      include GraphQL::Schema::Interface
      field :sign_in, mutation: SignIn
    end

    class Mutation < GraphQL::Schema::Object
      implements Auth
    end

    mutation(Mutation)
    query(Mutation)
  end

  it "works when mutations are added via interfaces" do
    result = InterfaceMutationSchema.execute("mutation { signIn(login: \"abc\", password: \"abc\") { success } }")
    assert_equal true, result["data"]["signIn"]["success"]
  end
end
