# Accepts a hash with symbol keys.
# - convert keys to strings
# - if the value responds to `name=`, then assign the hash key as `name`
class GraphQL::StringNamedHash
  attr_reader :to_h
  def initialize(input_hash)
    @to_h = input_hash
      .reduce({}) { |memo, (key, value)| memo[key.to_s] = value; memo }
    # Set the name of the value based on its key
    @to_h.each {|k, v| v.respond_to?("name=") && v.name = k }
  end
end
