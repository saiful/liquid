module Liquid

  # Context keeps the variable stack and resolves variables, as well as keywords
  #
  #   context['variable'] = 'testing'
  #   context['variable'] #=> 'testing'
  #   context['true']     #=> true
  #   context['10.2232']  #=> 10.2232
  #
  #   context.stack do
  #      context['bob'] = 'bobsen'
  #   end
  #
  #   context['bob']  #=> nil  class Context
  class Context
    attr_reader :scopes, :errors, :registers, :environments, :resource_limits

    def initialize(environments = {}, outer_scope = {}, registers = {}, rethrow_errors = false, resource_limits = {})
      @environments    = [environments].flatten
      @scopes          = [(outer_scope || {})]
      @registers       = registers
      @errors          = []
      @rethrow_errors  = rethrow_errors
      @resource_limits = (resource_limits || {}).merge!({ :render_score_current => 0, :assign_score_current => 0 })
      squash_instance_assigns_with_environments

      @interrupts = []
      @filters = []
    end

    def increment_used_resources(key, obj)
      @resource_limits[key] += if obj.kind_of?(String) || obj.kind_of?(Array) || obj.kind_of?(Hash)
        obj.length
      else
        1
      end
    end

    def resource_limits_reached?
      (@resource_limits[:render_length_limit] && @resource_limits[:render_length_current] > @resource_limits[:render_length_limit]) ||
      (@resource_limits[:render_score_limit]  && @resource_limits[:render_score_current]  > @resource_limits[:render_score_limit] ) ||
      (@resource_limits[:assign_score_limit]  && @resource_limits[:assign_score_current]  > @resource_limits[:assign_score_limit] )
    end

    def strainer
      @strainer ||= Strainer.create(self, @filters)
    end

    # Adds filters to this context.
    #
    # Note that this does not register the filters with the main Template object. see <tt>Template.register_filter</tt>
    # for that
    def add_filters(filters)
      filters = [filters].flatten.compact
      filters.each do |f|
        raise ArgumentError, "Expected module but got: #{f.class}" unless f.is_a?(Module)
        Strainer.add_known_filter(f)
      end

      # If strainer is already setup then there's no choice but to use a runtime
      # extend call. If strainer is not yet created, we can utilize strainers
      # cached class based API, which avoids busting the method cache.
      if @strainer
        filters.each do |f|
          strainer.extend(f)
        end
      else
        @filters.concat filters
      end
    end

    # are there any not handled interrupts?
    def has_interrupt?
      @interrupts.any?
    end

    # push an interrupt to the stack. this interrupt is considered not handled.
    def push_interrupt(e)
      @interrupts.push(e)
    end

    # pop an interrupt from the stack
    def pop_interrupt
      @interrupts.pop
    end

    def handle_error(e)
      errors.push(e)
      raise if @rethrow_errors

      case e
      when SyntaxError
        "Liquid syntax error: #{e.message}"
      else
        "Liquid error: #{e.message}"
      end
    end

    def invoke(method, *args)
      strainer.invoke(method, *args)
    end

    # Push new local scope on the stack. use <tt>Context#stack</tt> instead
    def push(new_scope={})
      @scopes.unshift(new_scope)
      raise StackLevelError, "Nesting too deep" if @scopes.length > 100
    end

    # Merge a hash of variables in the current local scope
    def merge(new_scopes)
      @scopes[0].merge!(new_scopes)
    end

    # Pop from the stack. use <tt>Context#stack</tt> instead
    def pop
      raise ContextError if @scopes.size == 1
      @scopes.shift
    end

    # Pushes a new local scope on the stack, pops it at the end of the block
    #
    # Example:
    #   context.stack do
    #      context['var'] = 'hi'
    #   end
    #
    #   context['var]  #=> nil
    def stack(new_scope={})
      push(new_scope)
      yield
    ensure
      pop
    end

    def clear_instance_assigns
      @scopes[0] = {}
    end

    # Only allow String, Numeric, Hash, Array, Proc, Boolean or <tt>Liquid::Drop</tt>
    def []=(key, value)
      @scopes[0][key] = value
    end

    def [](key)
      resolve(key)
    end

    def has_key?(key)
      resolve(key) != nil
    end

    private
      LITERALS = {
        nil => nil, 'nil' => nil, 'null' => nil, '' => nil,
        'true'  => true,
        'false' => false,
        'blank' => :blank?,
        'empty' => :empty?
      }

      # Look up variable, either resolve directly after considering the name. We can directly handle
      # Strings, digits, floats and booleans (true,false).
      # If no match is made we lookup the variable in the current scope and
      # later move up to the parent blocks to see if we can resolve the variable somewhere up the tree.
      # Some special keywords return symbols. Those symbols are to be called on the rhs object in expressions
      #
      # Example:
      #   products == empty #=> products.empty?
      def resolve(key)
        if LITERALS.key?(key)
          LITERALS[key]
        else
          case key
          when /^'(.*)'$/ # Single quoted strings
            $1
          when /^"(.*)"$/ # Double quoted strings
            $1
          when /^(-?\d+)$/ # Integer and floats
            $1.to_i
          when /^\((\S+)\.\.(\S+)\)$/ # Ranges
            (resolve($1).to_i..resolve($2).to_i)
          when /^(-?\d[\d\.]+)$/ # Floats
            $1.to_f
          else
            variable(key)
          end
        end
      end

      # Fetches an object starting at the local scope and then moving up the hierachy
      def find_variable(key)
        scope = @scopes.find { |s| s.has_key?(key) }
        variable = nil

        if scope.nil?
          @environments.each do |e|
            if variable = lookup_and_evaluate(e, key)
              scope = e
              break
            end
          end
        end

        scope     ||= @environments.last || @scopes.last
        variable  ||= lookup_and_evaluate(scope, key)

        variable = variable.to_liquid
        variable.context = self if variable.respond_to?(:context=)

        return variable
      end

      # Resolves namespaced queries gracefully.
      #
      # Example
      #  @context['hash'] = {"name" => 'tobi'}
      #  assert_equal 'tobi', @context['hash.name']
      #  assert_equal 'tobi', @context['hash["name"]']
      def variable(markup)
        parts = markup.scan(VariableParser)
        square_bracketed = /^\[(.*)\]$/

        first_part = parts.shift

        if first_part =~ square_bracketed
          first_part = resolve($1)
        end

        if object = find_variable(first_part)

          parts.each do |part|
            part = resolve($1) if part_resolved = (part =~ square_bracketed)

            # If object is a hash- or array-like object we look for the
            # presence of the key and if its available we return it
            if object.respond_to?(:[]) and
              ((object.respond_to?(:has_key?) and object.has_key?(part)) or
               (object.respond_to?(:fetch) and part.is_a?(Integer)))

              # if its a proc we will replace the entry with the proc
              res = lookup_and_evaluate(object, part)
              object = res.to_liquid

              # Some special cases. If the part wasn't in square brackets and
              # no key with the same name was found we interpret following calls
              # as commands and call them on the current object
            elsif !part_resolved and object.respond_to?(part) and ['size', 'first', 'last'].include?(part)

              object = object.send(part.intern).to_liquid

              # No key was present with the desired value and it wasn't one of the directly supported
              # keywords either. The only thing we got left is to return nil
            else
              return nil
            end

            # If we are dealing with a drop here we have to
            object.context = self if object.respond_to?(:context=)
          end
        end

        object
      end # variable

      def lookup_and_evaluate(obj, key)
        if (value = obj[key]).is_a?(Proc) && obj.respond_to?(:[]=)
          obj[key] = (value.arity == 0) ? value.call : value.call(self)
        else
          value
        end
      end # lookup_and_evaluate

      def squash_instance_assigns_with_environments
        @scopes.last.each_key do |k|
          @environments.each do |env|
            if env.has_key?(k)
              scopes.last[k] = lookup_and_evaluate(env, k)
              break
            end
          end
        end
      end # squash_instance_assigns_with_environments
  end # Context

end # Liquid
