require "spec_helper"
require "graphql/generators/install_generator"

class GraphQLGeneratorsInstallGeneratorTest < Rails::Generators::TestCase

  tests GraphQL::Generators::InstallGenerator
  destination File.expand_path("../../tmp/dummy", File.dirname(__FILE__))

  setup do
    FileUtils.cd(File.expand_path("../../tmp", File.dirname(__FILE__))) do
      `rm -rf dummy`
      `rails new dummy --skip-active-record --skip-test-unit --skip-spring --skip-bundle`
    end
  end

  test "it generates a folder structure" do
    run_generator([])

    assert_file "app/graphql/types/.keep"
    assert_file "app/graphql/mutations/.keep"
    assert_file "app/graphql/resolvers/.keep"
    expected_query_route = "resource :graphql, only: :create"
    expected_graphiql_route = %|
  if Rails.env.development?
    mount GraphiQL::Rails::Engine, at: "/graphiql", graphql_path: "/graphql"
  end
|

    assert_file "config/routes.rb" do |contents|
      assert_includes contents, expected_query_route
      assert_includes contents, expected_graphiql_route
    end

    assert_file "Gemfile" do |contents|
      assert_includes contents, "gem 'graphiql-rails', group: :development"
    end

    expected_schema = <<-RUBY
DummySchema = GraphQL::Schema.define do
  query(Types::QueryType)
end
RUBY
    assert_file "app/graphql/dummy_schema.rb", expected_schema


    expected_query_type = <<-RUBY
Types::QueryType = GraphQL::ObjectType.define do
  name "Query"
  # Add root-level fields here.
  # They will be entry points for queries on your schema.
end
RUBY

    assert_file "app/graphql/types/query_type.rb", expected_query_type
    assert_file "app/controllers/graphqls_controller.rb", EXPECTED_GRAPHQLS_CONTROLLER
  end

  test "it generates graphql-batch and relay boilerplate" do
    run_generator(["--batch", "--relay"])
    assert_file "app/graphql/loaders/.keep"
    assert_file "Gemfile" do |contents|
      assert_includes contents, "gem 'graphql-batch'"
    end

    expected_query_type = <<-RUBY
Types::QueryType = GraphQL::ObjectType.define do
  name "Query"
  # Add root-level fields here.
  # They will be entry points for queries on your schema.
  field :node, GraphQL::Relay::Node.field
end
RUBY

    assert_file "app/graphql/types/query_type.rb", expected_query_type
    assert_file "app/graphql/dummy_schema.rb", EXPECTED_RELAY_BATCH_SCHEMA
  end

  test "it can skip keeps, skip graphiql and customize schema name" do
    run_generator(["--skip-keeps", "--skip-graphiql", "--schema=CustomSchema"])
    assert_no_file "app/graphql/types/.keep"
    assert_no_file "app/graphql/mutations/.keep"
    assert_no_file "app/graphql/resolvers/.keep"
    assert_file "app/graphql/types"
    assert_file "app/graphql/mutations"
    assert_file "app/graphql/resolvers"
    assert_file "Gemfile" do |contents|
      refute_includes contents, "graphiql-rails"
    end

    assert_file "config/routes.rb" do |contents|
      refute_includes contents, "GraphiQL::Rails"
    end

    assert_file "app/graphql/custom_schema.rb", /CustomSchema = GraphQL::Schema\.define/
    assert_file "app/controllers/graphqls_controller.rb", /CustomSchema\.execute/
  end

  EXPECTED_GRAPHQLS_CONTROLLER = <<-RUBY
class GraphqlsController < ApplicationController
  def create
    variables = ensure_hash(params[:variables])
    query = params[:query]
    context = {
      # Query context goes here, for example:
      # current_user: current_user,
    }
    result = DummySchema.execute(query, variables: variables, context: context)
    render json: result
  end

  private

  # Handle form data, JSON body, or a blank value
  def ensure_hash(ambiguous_param)
    case ambiguous_param
    when String
      if ambiguous_param.present?
        JSON.parse(ambiguous_param)
      else
        {}
      end
    when Hash
      ambiguous_param
    else
      {}
    end
  end
end
RUBY

  EXPECTED_RELAY_BATCH_SCHEMA = <<-RUBY
DummySchema = GraphQL::Schema.define do
  query(Types::QueryType)

  # Relay Object Identification:

  # Return a string UUID for `object`
  id_from_object ->(object, type_definition, query_ctx) {
    # Here's a simple implementation which:
    # - joins the type name & object.id
    # - encodes it with base64:
    # GraphQL::Schema::UniqueWithinType.encode(type_definition.name, object.id)
  }

  # Given a string UUID, find the object
  object_from_id ->(id, query_ctx) {
    # For example, to decode the UUIDs generated above:
    # type_name, item_id = GraphQL::Schema::UniqueWithinType.decode(id)
    #
    # Then, based on `type_name` and `id`
    # find an object in your application
    # ...
  }

  # GraphQL::Batch setup:
  lazy_resolve(Promise, :sync)
  instrument(:query, GraphQL::Batch::Setup)
end
RUBY
end
