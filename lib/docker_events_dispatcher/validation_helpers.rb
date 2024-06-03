module DockerEventsDispatcher
  module ValidationHelpers
    def validated_accessor(name, validator = nil)
      validator ||= "validate_#{name}"
      attr_reader name

      define_method("#{name}=") do |value|
        instance_variable_set("@#{name}", send(validator, value))
      end
    end

    def self.included(mod)
      mod.extend self
    end
  end
end
