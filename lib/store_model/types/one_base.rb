# frozen_string_literal: true

require "active_model"

module StoreModel
  module Types
    # Implements type for handling an instance of StoreModel::Model
    class OneBase < Base
      # A model initializer may require the input to be an exact Hash.
      module RecoveringAttributes
        attr_reader :unknown_attributes

        def configure_recovery(unknown_attributes, &recoverable)
          @recoverable = recoverable
          @unknown_attributes = unknown_attributes
          self
        end

        def dup
          copy = super
          copy.extend(RecoveringAttributes)
          copy.configure_recovery(unknown_attributes, &@recoverable)
        end

        def merge(*others, &block)
          merged = super
          merged.extend(RecoveringAttributes)
          merged.configure_recovery(unknown_attributes, &@recoverable)
        end

        def each
          return enum_for(:each) unless block_given?

          super do |key, value|
            yield key, value
          rescue ActiveModel::UnknownAttributeError => e
            raise unless @recoverable.call(key, e)

            record_unknown(key, value)
          end
        end
        alias each_pair each

        def record_unknown(key, value)
          string_key = key.to_s
          unknown_attributes[string_key] = value if key.is_a?(String) || !unknown_attributes.key?(string_key)
        end
      end

      # Casts +value+ from DB or user to StoreModel::Model instance
      #
      # @param value [Object] a value to cast
      #
      # @return StoreModel::Model
      def cast_value(_value)
        raise NotImplementedError
      end

      # Determines whether the mutable value has been modified since it was read
      #
      # @param raw_old_value [Object] old value
      # @param new_value [Object] new value
      #
      # @return [Boolean]
      def changed_in_place?(raw_old_value, new_value)
        cast_value(raw_old_value) != new_value
      end

      protected

      def model_instance(_value)
        raise NotImplementedError
      end

      private

      # rubocop:disable Style/RescueModifier
      def decode_and_initialize(value)
        decoded = ActiveSupport::JSON.decode(value) rescue nil
        model_instance(decoded) unless decoded.nil?
      rescue ActiveModel::UnknownAttributeError => e
        handle_unknown_attribute(decoded, e)
      end
      # rubocop:enable Style/RescueModifier

      def handle_unknown_attribute(value, exception)
        input = input_attributes(value, exception)
        pairs = unwrap_attributes(input).to_a
        failed_index = pairs.index { |key, _| key.to_s == exception.attribute.to_s }
        failed_model = exception.record
        model_class = expected_model_class(input)
        validate_unknown_attribute!(failed_model, model_class, pairs, failed_index, exception)

        recover_model(model_class, pairs, failed_index, exception)
      end

      def recover_model(model_class, pairs, failed_index, exception)
        return retry_duplicate_attribute(pairs, exception) if duplicate_attribute?(pairs, exception.attribute)

        key, value = pairs.fetch(failed_index)
        attributes = pairs.to_h.except(key)
        recovering = attributes.extend(RecoveringAttributes)
        recovering.configure_recovery({}) do |current_key, error|
          recoverable_missing_writer?(model_class, current_key, error)
        end
        recovering.record_unknown(key, value)

        model_class.new(recovering).tap { |model| model.unknown_attributes.update(recovering.unknown_attributes) }
      end

      def input_attributes(value, exception)
        raise exception unless value.respond_to?(:to_h)

        value.to_h
      end

      def validate_unknown_attribute!(failed_model, model_class, pairs, failed_index, exception)
        raise exception unless failed_index && failed_model.is_a?(StoreModel::Model)
        raise exception unless selected_model_record?(failed_model, model_class)
        raise exception unless missing_writer_error?(failed_model, exception)

        failed_key = pairs.fetch(failed_index).first
        raise exception if failed_model.respond_to?("#{failed_key}=")
      end

      def selected_model_record?(record, model_class)
        record.instance_of?(model_class) ||
          (model_class.method(:new).owner != Class && record.is_a?(model_class))
      end

      def recoverable_missing_writer?(model_class, key, exception)
        record = exception.record
        return false unless record.is_a?(model_class)
        return false unless exception.attribute.to_s == key.to_s
        return false if record.respond_to?("#{key}=")

        missing_writer_error?(record, exception)
      end

      def missing_writer_error?(record, exception)
        # ActiveModel 7.0 and 7.1 raise directly when the writer is missing.
        return true if ActiveModel::VERSION::MAJOR == 7 && ActiveModel::VERSION::MINOR < 2

        cause = exception.cause
        cause.is_a?(NoMethodError) && cause.name == :"#{exception.attribute}=" && cause.receiver.equal?(record)
      rescue ArgumentError
        false
      end

      def expected_model_class(attributes)
        return @model_klass if defined?(@model_klass)

        extract_model_klass(attributes)
      end

      def duplicate_attribute?(pairs, attribute)
        pairs.count { |key, _| key.to_s == attribute.to_s } > 1
      end

      def retry_duplicate_attribute(pairs, exception)
        attributes = pairs.to_h
        key = attributes.key?(exception.attribute.to_s) ? exception.attribute.to_s : exception.attribute.to_sym

        cast_value(attributes.except(key)).tap do |model|
          model.unknown_attributes[exception.attribute.to_s] = attributes.fetch(key, nil)
        end
      end

      def unwrap_attributes(value)
        value.fetch(:attributes) { value.fetch("attributes", value) }
      end
    end
  end
end
