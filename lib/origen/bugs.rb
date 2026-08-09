module Origen
  module Bugs
    extend ActiveSupport::Concern

    autoload :Bug, 'origen/bugs/bug'

    module ClassMethods # :nodoc:
      # Define a bug on the given IP
      def bug(name, options = {})
        name = name.to_s.downcase.to_sym
        bugs[name] = Bug.new(name, options)
        define_method "has_#{name}_bug?" do
          Origen.deprecate "Use has_bug?(:#{name}) instead of has_#{name}_bug?"
          has_bug?(name)
        end
      end

      def bugs
        @bugs ||= {}
      end
    end

    # Returns true if the IP represented by the object has the bug of the given name.
    # Bugs explicitly declared with unfixable: true can be queried without a version
    # attribute.
    def has_bug?(name, _options = {})
      name = name.to_s.downcase.to_sym

      if bug = bugs[name]
        return true if bug.unfixable?

        # Note - jinyakok: Only check for version if a bug actually exists.
        unless respond_to?(:version) && version
          puts 'To test for the presence of a versioned bug the object must implement an attribute'
          puts "called 'version' which returns the IP version represented by the the object."
          fail 'Version undefined!'
        end
  
        bug.present_on_version?(version)
      else
        false
      end
    end

    # Returns a hash containing all known bugs associated with
    # the given IP, regardless of which version they are present on
    def bugs
      self.class.bugs
    end
  end
end
