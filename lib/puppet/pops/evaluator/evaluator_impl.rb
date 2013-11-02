require 'rgen/ecore/ecore'
require 'puppet/pops/evaluator/compare_operator'
require 'puppet/pops/evaluator/relationship_operator'
require 'puppet/pops/evaluator/access_operator'
require 'puppet/pops/evaluator/closure'

# This implementation of {Puppet::Pops::Evaluator} performs evaluation using the puppet 3.x runtime system
# in a manner largely compatible with Puppet 3.x, but adds new features and introduces constraints.
#
# The evaluation uses _polymorphic dispatch_ which works by dispatching to the first found method named after
# the class or one of its super-classes. The EvaluatorImpl itself mainly deals with evaluation (it currently
# also handles assignment), and it uses a delegation pattern to more specialized handlers of some operators
# that in turn use polymorphic dispatch; this to not clutter EvaluatorImpl with too much responsibility).
#
# Since a pattern is used, only the main entry points are fully documented. The parameters _o_ and _scope_ are
# the same in all the polymorphic methods, (the type of the parameter _o_ is reflected in the method's name;
# either the actual class, or one of its super classes). The _scope_ parameter is always the scope in which
# the evaluation takes place. If nothing else is mentioned, the return is always the result of evaluation.
#
# See {Puppet::Pops::Visitable} and {Puppet::Pops::Visitor} for more information about
# polymorphic calling.
# @api private
#
class Puppet::Pops::Evaluator::EvaluatorImpl # < Puppet::Pops::Evaluator
  include Puppet::Pops::Utils

  # Provides access to the Puppet 3.x runtime (scope, etc.)
  # This separation has been made to make it easier to later migrate the evaluator to an improved runtime.
  #
  include Puppet::Pops::Evaluator::Runtime3Support

  # Reference to Issues name space makes it easier to refer to issues
  # (Issues are shared with the validator).
  #
  Issues = Puppet::Pops::Issues

  def initialize
    @@eval_visitor     ||= Puppet::Pops::Visitor.new(self, "eval", 1, 1)
    @@lvalue_visitor   ||= Puppet::Pops::Visitor.new(self, "lvalue", 1, 1)
    @@assign_visitor   ||= Puppet::Pops::Visitor.new(self, "assign", 3, 3)
    @@call_visitor     ||= Puppet::Pops::Visitor.new(self, "call", 3, 3)

    @@type_calculator  ||= Puppet::Pops::Types::TypeCalculator.new()
    @@type_parser      ||= Puppet::Pops::Types::TypeParser.new()

    @@compare_operator     ||= Puppet::Pops::Evaluator::CompareOperator.new()
    @@relationship_operator ||= Puppet::Pops::Evaluator::RelationshipOperator.new()
  end

  # Polymorphic evaluate - calls eval_TYPE
  #
  # ## Polymorphic evaluate
  # Polymorphic evaluate calls a method on the format eval_TYPE where classname is the last
  # part of the class of the given _target_. A search is performed starting with the actual class, continuing
  # with each of the _target_ class's super classes until a matching method is found.
  #
  # # Description
  # Evaluates the given _target_ object in the given scope, optionally passing a block which will be
  # called with the result of the evaluation.
  #
  # @overload evaluate(target, scope, {|result| block})
  # @param target [Object] evaluation target - see methods on the pattern assign_TYPE for actual supported types.
  # @param scope [Object] the runtime specific scope class where evaluation should take place
  # @return [Object] the result of the evaluation
  # @yieldparam [Object] the result of the evaluation of target
  # @yieldreturn [Object] the result of evaluating the optional block
  #
  # @api
  #
  def evaluate(target, scope, &block)
    x = @@eval_visitor.visit_this(self, target, scope)
    if block_given?
      block.call(x)
    else
      x
    end
  end

  # Polymorphic assign - calls assign_TYPE.
  #
  # # Polymorphic assign
  # Polymorphic assign calls a method on the format assign_TYPE where TYPE is the last
  # part of the class of the given _target_. A search is performed starting with the actual class, continuing
  # with each of the _target_ class's super classes until a matching method is found.
  #
  # # Description
  # Assigns the given _value_ to the given _target_. The additional argument _o_ is the instruction that
  # produced the target/value tuple and it is used to set the origin of the result.
  # @param target [Object] assignment target - see methods on the pattern assign_TYPE for actual supported types.
  # @param value [Object] the value to assign to `target`
  # @param o [Puppet::Pops::Model::PopsObject] originating instruction
  # @param scope [Object] the runtime specific scope where evaluation should take place

  def assign(target, value, o, scope)
    @@assign_visitor.visit_this(self, target, value, o, scope)
  end

  def lvalue(o, scope)
    @@lvalue_visitor.visit_this(self, o, scope)
  end

  # Call a closure - Can only be called with a Closure (for now), may be refactored later
  # to also handle other types of calls (function calls are also handled by CallNamedFunction and CallMethod, they
  # could create similar objects to Closure, wait until other types of defines are instantiated - they may behave
  # as special cases of calls - i.e. 'new')
  #
  # @raise ArgumentError, if there are to many or too few arguments
  # @raise ArgumentError, if given closure is not a Puppet::Pops::Evaluator::Closure
  #
  def call(closure, args, scope, &block)
    raise ArgumentError, "Can only call a Lambda" unless closure.is_a?(Puppet::Pops::Evaluator::Lambda)
    pblock = closure.model
    parameters = pblock.parameters || []

    raise ArgumentError, "Too many arguments: #{args.size} for #{parameters.size}" unless args.size <= parameters.size

    # associate values with parameters
    merged = parameters.zip(args)
    # calculate missing arguments
    missing = parameters.slice(args.size, parameters.size - args.size).select {|p| e.value.nil? }
    unless missing.empty?
      optional = parameters.count { |p| !p.value.nil? }
      raise ArgumentError, "Too few arguments; #{args.size} for #{optional > 0 ? ' min ' : ''}#{parameters.size - optional}"
    end

    evaluated = merged.collect do |m|
      # m can be one of
      # m = [Parameter{name => "name", value => nil], "given"]
      #   | [Parameter{name => "name", value => Expression}, "given"]
      #
      # "given" is always an optional entry. If a parameter was provided then
      # the entry will be in the array, otherwise the m array will be a
      # single element.a = []
      given_argument = m[1]
      argument_name = m[0].name
      default_expression = m[0].value

      value = if default_expression
        evaluate(default_expression, scope)
      else
        given_argument
      end
      [argument_name, value]
    end

    # Store the evaluated name => value associations in a new inner/local/ephemeral scope
    # (This is made complicated due to the fact that the implementation of scope is overloaded with
    # functionality and an inner ephemeral scope must be used (as opposed to just pushing a local scope
    # on a scope "stack").

    # Ensure variable exists with nil value if error occurs. 
    # Some ruby implementations does not like creating variable on return
    result = nil
    begin
      scope_memo = get_scope_nesting_level(scope)
      # change to create local scope_from - cannot give it file and line - that is the place of the call, not
      # "here"
      create_local_scope_from(Hash[evaluated], scope)
      result = evaluate(pblock.body, scope)
    ensure
      set_scope_nesting_level(scope, scope_memo)
    end
    if block_given?
      block.call(result)
    else
      result
    end
  end

  protected

  def lvalue_VariableExpression(o, scope)
    # evaluate the name
    evaluate(o.expr, scope)
  end

  def lvalue_LiteralList(o, scope)
    evaluate(o.expr, scope)
  end

  # Catches all illegal lvalues
  #
  def lvalue_Object(o, scope)
    fail(Issues::ILLEGAL_ASSIGNMENT, o)
  end

  # Assign value to named variable.
  # The '$' sign is never part of the name.
  # @example In Puppet DSL
  #   $name = value
  # @param name [String] name of variable without $
  # @param value [Object] value to assign to the variable
  # @param o [Puppet::Pops::Model::PopsObject] originating instruction
  # @param scope [Object] the runtime specific scope where evaluation should take place
  # @return [value<Object>]
  #
  def assign_String(name, value, o, scope)
    if name =~ /::/
      fail(Issues::CROSS_SCOPE_ASSIGNMENT, o.left_expr, {:name => name})
    end
    set_variable(name, value, o, scope)
    value
  end

  def assign_Numeric(n, value, o, scope)
    fail(Issues::ILLEGAL_NUMERIC_ASSIGNMENT, o.left_expr, {:varname => n.to_s})
  end

  # Assign values to named variables in an array.
  # The '$' sign is never part of the name.
  # @example Puppet DSL
  #   # all set to 10
  #   [a, b, c] = 10
  #
  #   # set from matching entry in hash
  #   [a, b, c] = {a => 10, b => 20, c => 30}
  #
  #   # set in sequence from array
  #   [a, b, c] = [1,2,3]
  #
  # @param names [Array<String>] array of variable names without $
  # @param value [Object] value to assign to each variable
  # @param o [Puppet::Pops::Model::PopsObject] originating instruction
  # @param scope [Object] the runtime specific scope where evaluation should take place
  # @return [value<Object>]
  #
  def assign_Array(names, value, o, scope)
    case value
    when Array
      names.zip(value).each {|x| set_variable(x, value, o, scope) }
    when Hash
      names.each {|x| set_variable(x, value[x], o, scope) }
    else
      names.each {|x| set_variable(x, value, o, scope) }
    end
    value
  end

  # Catches all illegal assignment (e.g. 1 = 2, {'a'=>1} = 2, etc)
  #
  def assign_Object(name, value, o, scope)
    fail(Issues::ILLEGAL_ASSIGNMENT, o)
  end

  def eval_Factory(o, scope)
    evaluate(o.current, scope)
  end

  # Evaluates any object not evaluated to something else to itself.
  def eval_Object o, scope
    o
  end

  # Allows nil to be used as a Nop.
  # Evaluates to nil
  # TODO: What is the difference between literal undef, nil, and nop?
  #
  def eval_NilClass(o, scope)
    nil
  end

  # Evaluates Nop to nil.
  # TODO: or is this the same as :undef
  # TODO: is this even needed as a separate instruction when there is a literal undef?
  def eval_Nop(o, scope)
    nil
  end

  # Captures all LiteralValues not handled elsewhere.
  #--
  # QualifiedName < LiteralValue  end
  def eval_LiteralValue(o, scope)
    o.value
  end

  def eval_LiteralDefault(o, scope)
    :default
  end

  def eval_LiteralUndef(o, scope)
    :undef # TODO: or just use nil for this?
  end

  # A QualifiedReference (i.e. a  capitalized qualified name such as Foo, or Foo::Bar) evaluates to a PType
  #
  def eval_QualifiedReference(o, scope)
    @@type_parser.interpret(o)
  end

  def eval_NotExpression(o, scope)
    ! is_true?(evaluate(o.expr, scope))
  end

  def eval_UnaryMinusExpression(o, scope)
    - box_numeric(evaluate(o.expr, scope), o, scope)
  end

  # Abstract evaluation, returns array [left, right] with the evaluated result of left_expr and
  # right_expr
  # @return <Array<Object, Object>> array with result of evaluating left and right expressions
  #
  def eval_BinaryExpression o, scope
    [ evaluate(o.left_expr, scope), evaluate(o.right_expr, scope) ]
  end

  # Evaluates assignment with operators =, +=, -= and
  #
  # @example Puppet DSL
  #   $a = 1
  #   $a += 1
  #   $a -= 1
  #
  def eval_AssignmentExpression(o, scope)

    name = lvalue(o.left_expr, scope)
    value = evaluate(o.right_expr, scope)

    case o.operator
    when :'=' # regular assignment
      assign(name, value, o, scope)

    when :'+='
      # if value does not exist, return RHS (note that type check has already been made so correct type is ensured)
      if !variable_exists?(name, scope)
        return value
      end
      begin
        # Delegate to calculate function to deal with check of LHS, and perform ´+´ as arithmetic or concatenation the
        # same way as ArithmeticExpression performs `+`.
        assign(name, calculate(get_variable_value(name, o, scope), value, :'+', o.left_expr, o.right_expr, scope), o, scope)
      rescue ArgumentError => e
        fail(Issues::APPEND_FAILED, o, {:message => e.message})
      end

    when :'-='
      # If an attempt is made to delete values from something that does not exists, the value is :undef (it is guaranteed to not
      # include any values the user wants deleted anyway :-)
      #
      if !variable_exists?(name, scope)
        return nil
      end
      begin
        # Delegate to delete function to deal with check of LHS, and perform deletion
        assign(name, delete(get_variable_value(name, o, scope), value), o, scope)
      rescue ArgumentError => e
        fail(Issues::APPEND_FAILED, o, {:message => e.message})
      end
    else
      fail(Issues::UNSUPPORTED_OPERATOR, o, {:operator => o.operator})
    end
    value
  end

  ARITHMETIC_OPERATORS = [:'+', :'-', :'*', :'/', :'%', :'<<', :'>>']
  COLLECTION_OPERATORS = [:'+', :'-', :'<<']

  # Handles binary expression where lhs and rhs are array/hash or numeric and operator is +, - , *, % / << >>
  #
  def eval_ArithmeticExpression(o, scope)
    unless ARITHMETIC_OPERATORS.include?(o.operator)
      fail(Issues::UNSUPPORTED_OPERATOR, o, {:operator => o.operator})
    end
    left, right = eval_BinaryExpression(o, scope)
    begin
      result = calculate(left, right, o.operator, o.left_expr, o.right_expr, scope)
    rescue ArgumentError => e
      fail(Issues::RUNTIME_ERROR, o, {:detail => e.message}, e)
    end
    result
  end


  # Handles binary expression where lhs and rhs are array/hash or numeric and operator is +, - , *, % / << >>
  #
  def calculate(left, right, operator, left_o, right_o, scope)
    unless ARITHMETIC_OPERATORS.include?(operator)
      fail(Issues::UNSUPPORTED_OPERATOR, left_o.eContainer, {:operator => o.operator})
    end

    if (left.is_a?(Array) || left.is_a?(Hash)) && COLLECTION_OPERATORS.include?(operator)
      # Handle operation on collections
      case operator
      when :'+'
        concatenate(left, right)
      when :'-'
        delete(left, right)
      when :'<<'
        unless left.is_a?(Array)
          fail(Issues::OPERATOR_NOT_APPLICABLE, left_o, {:operator => operator, :left_value => left})
        end
        left + [right]
      end
    else
      # Handle operation on numeric
      left = box_numeric(left, left_o, scope)
      right = box_numeric(right, right_o, scope)
      begin
        result = left.send(operator, right)
      rescue NoMethodError => e
        fail(Issues::OPERATOR_NOT_APPLICABLE, left_o, {:operator => operator, :left_value => left})
      end
      result
    end
  end

  # Evaluates Puppet DSL ->, ~>, <-, and <~
  def eval_RelationshipExpression(o, scope)
    # First level evaluation, reduction to basic data types or puppet types, the relationship operator then translates this
    # to the final set of references (turning strings into references, which can not naturally be done by the main evaluator since
    # all strings should not be turned into references.
    #
    real = eval_BinaryExpression(o, scope)
    @@relationship_operator.evaluate(real, o, scope)
  end

  # Evaluates x[key, key, ...]
  #
  def eval_AccessExpression(o, scope)
    left = evaluate(o.left_expr, scope)
    keys = o.keys.nil? ? [] : o.keys.collect {|key| evaluate(key, scope) }
    Puppet::Pops::Evaluator::AccessOperator.new(o).access(left, scope, *keys)
  end

  # Evaluates <, <=, >, >=, and ==
  #
  def eval_ComparisonExpression o, scope
    left, right = eval_BinaryExpression o, scope

    begin
    # Left is a type
    if left.is_a?(Puppet::Pops::Types::PAbstractType)
      case o.operator
      when :'=='
        @@compare_operator.equals(left,right)
      when :'!='
        ! @@compare_operator.equals(left,right)
      when :'<'
        # right can be assigned to left, but they are not equal
        @@type_calculator.assignable?(left, right) && ! @@compare_operator.equals(left,right)
      when :'<='
        # right can be assigned to left
        @@type_calculator.assignable?(left, right)
      when :'>'
        # left can be assigned to right, but they are not equal
        @@type_calculator.assignable?(right, left) && ! @@compare_operator.equals(left,right)
      when :'>='
        # left can be assigned to right
        @@type_calculator.assignable?(right, left)
      else
        fail(Issues::UNSUPPORTED_OPERATOR, o, {:operator => o.operator})
      end
    else
      case o.operator
      when :'=='
        @@compare_operator.equals(left,right)
      when :'!='
        ! @@compare_operator.equals(left,right)
      when :'<'
        @@compare_operator.compare(left,right) < 0
      when :'<='
        @@compare_operator.compare(left,right) <= 0
      when :'>'
        @@compare_operator.compare(left,right) > 0
      when :'>='
        @@compare_operator.compare(left,right) >= 0
      else
        fail(Issues::UNSUPPORTED_OPERATOR, o, {:operator => o.operator})
      end
    end
    rescue ArgumentError => e
      fail(Issues::COMPARISON_NOT_POSSIBLE, o, {
        :operator => o.operator,
        :left_value => left,
        :right_value => right,
        :detail => e.message})
    end
  end

  # Evaluates matching expressions with string or regexp rhs expression.
  #
  # @example
  #   x =~ /abc.*/
  # @example
  #   x =~ "abc.*/"
  # @example
  #   y = "abc"
  #   x =~ "${y}.*"
  # @return [Boolean] if a match was made or not. Also sets $0..$n to matchdata in current scope.
  #
  def eval_MatchExpression o, scope
    left, pattern = eval_BinaryExpression o, scope
    begin
      pattern = Regexp.new(pattern) unless pattern.is_a?(Regexp)
    rescue StandardError => e
      fail(Issues::MATCH_NOT_REGEXP, o.right_expr, {:detail => e.message})
    end
    unless left.is_a?(String)
      fail(Issues::MATCH_NOT_STRING, o.left_expr, {:left_value => left})
    end

    matched = pattern.match(left) # nil, or MatchData
    set_match_data(matched, o, scope) # creates ephemeral

    # convert match result to Boolean true, or false
    o.operator == :'=~' ? !!matched : !matched
  end

  # Evaluates Puppet DSL `in` expression
  #
  def eval_InExpression o, scope
    left, right = eval_BinaryExpression o, scope
    @@compare_operator.include?(right, left)
  end

  # @example
  #   $a and $b
  # b is only evaluated if a is true
  #
  def eval_AndExpression o, scope
    is_true?(evaluate(o.left_expr, scope)) ? is_true?(evaluate(o.right_expr, scope)) : false
  end

  # @example
  #   a or b
  # b is only evaluated if a is false
  #
  def eval_OrExpression o, scope
    is_true?(evaluate(o.left_expr, scope)) ? true : is_true?(evaluate(o.right_expr, scope))
  end

  # Evaluates each entry of the literal list and creates a new Array
  # @return [Array] with the evaluated content
  #
  def eval_LiteralList o, scope
    o.values.collect {|expr| evaluate(expr, scope)}
  end

  # Evaluates each entry of the literal hash and creates a new Hash.
  # @return [Hash] with the evaluated content
  #
  def eval_LiteralHash o, scope
    h = Hash.new
    o.entries.each {|entry| h[ evaluate(entry.key, scope)]= evaluate(entry.value, scope)}
    h
  end

  # Evaluates all statements and produces the last evaluated value
  #
  def eval_BlockExpression o, scope
    r = nil
    o.statements.each {|s| r = evaluate(s, scope)}
    r
  end

  # Performs optimized search over case option values, lazily evaluating each
  # until there is a match. If no match is found, the case expression's default expression
  # is evaluated (it may be nil or Nop if there is no default, thus producing nil).
  # If an option matches, the result of evaluating that option is returned.
  # @return [Object, nil] what a matched option returns, or nil if nothing matched.
  #
  def eval_CaseExpression(o, scope)
    # memo scope level before evaluating test - don't want a match in the case test to leak $n match vars
    # to expressions after the case expression.
    #
    with_guarded_scope(scope) do
      test = evaluate(o.test, scope)
      result = nil
      the_default = nil
      if o.options.find do |co|
        # the first case option that matches
        if co.values.find do |c|
          the_default = co.then_expr if c.is_a? Puppet::Pops::Model::LiteralDefault
          is_match?(test, evaluate(c, scope), c, scope)
        end
        result = evaluate(co.then_expr, scope)
        true # the option was picked
        end
      end
        result # an option was picked, and produced a result
      else
        evaluate(the_default, scope) # evaluate the default (should be a nop/nil) if there is no default).
      end
    end
  end

  # @todo not implemented - maybe not needed; this is an abstract class
  def eval_QueryExpression o, scope
    # TODO: or remove - this is the abstract query
  end

  # @todo not implemented
  def eval_ExportedQuery o, scope
    # TODO
  end

  # @todo not implemented
  def eval_VirtualQuery o, scope
    # TODO
  end

  # @todo not implemented
  def eval_AttributeOperation o, scope
    # TODO
  end

  # @todo not implemented
  def eval_OptionalAttributeOperation o, scope
    # TODO
  end

  # @todo not implemented
  def eval_CollectExpression o, scope
    # TODO
  end

  # @todo not implemented
  def eval_Parameter o, scope
    # TODO
  end

  def eval_ParenthesizedExpression(o, scope)
    evaluate(o.expr, scope)
  end

  # TODO:
  # Definition < Expression (abstract)
  # NamedDefinition < Definition (abstract)
  # ResourceTypeDefinition < NamedDefinition

  # NodeDefinition < Expression
  # HostClassDefinition < NamedDefinition
  # ResourceExpression < Expression
  #    class ResourceBody < ASTObject
  # ResourceDefaultsExpression < Expression
  # ResourceOverrideExpression < Expression
  # NamedAccessExpression < Expression

  # Puppet 3.1 AST only supports calling a function by name (it is not possible to produce a function
  # that is then called). TODO- should puppet 4 accept this? It is very powerful in combiantion with
  # custom functions in puppet language.
  #
  # rval_required (for an expression)
  # functor_expr (lhs - the "name" expression)
  # arguments - list of arguments
  #
  def eval_CallNamedFunctionExpression(o, scope)
    # The functor expression is not evaluated, it is not possible to select the function to call
    # via an expression like $a()
    unless o.functor_expr.is_a? Puppet::Pops::Model::QualifiedName
      fail(Issues::ILLEGAL_EXPRESSION, o.functor_expr, {:feature=>'function name', :container => o})
    end
    name = o.functor_expr.value
    assert_function_available(name, o, scope)
    evaluated_arguments = o.arguments.collect {|arg| evaluate(arg, scope) }
    # wrap lambda in a callable block if it is present
    evaluated_arguments << Puppet::Pops::Evaluator::Lambda.new(self, o.lambda, scope) if o.lambda
    call_function(name, evaluated_arguments, o, scope) do |result|
      # prevent functions that are not r-value from leaking its return value
      rvalue_function?(name, o, scope) ? result : nil
    end
  end

  # Evaluation of CallMethodExpression handles a NamedAccessExpression functor (receiver.function_name)
  #
  def eval_CallMethodExpression(o, scope)
    unless o.functor_expr.is_a? Puppet::Pops::Model::NamedAccessExpression
      fail(Issues::ILLEGAL_EXPRESSION, o.functor_expr, {:feature=>'function accessor', :container => o})
    end
    receiver = evaluate(o.functor_expr.left_expr, scope)
    name = o.functor_expr.right_expr
    unless name.is_a? Puppet::Pops::Model::QualifiedName
      fail(Issues::ILLEGAL_EXPRESSION, o.functor_expr, {:feature=>'function name', :container => o})
    end 
    name = name.value # the string function name
    assert_function_available(name, o, scope)
    evaluated_arguments = [receiver] + (o.arguments || []).collect {|arg| evaluate(arg, scope) }
    evaluated_arguments << Puppet::Pops::Evaluator::Lambda.new(self, o.lambda, scope) if o.lambda
    call_function(name, evaluated_arguments, o, scope) do |result|
      # prevent functions that are not r-value from leaking its return value
      rvalue_function?(name, o, scope) ? result : nil
    end
  end

  # @example
  #   $x ? { 10 => true, 20 => false, default => 0 }
  #
  def eval_SelectorExpression o, scope
    # memo scope level before evaluating test - don't want a match in the case test to leak $n match vars
    # to expressions after the selector expression.
    #
    with_guarded_scope(scope) do
      test = evaluate(o.left_expr, scope)
      selected = o.selectors.find {|s|
        evaluate(s.matching_expr, scope) {|candidate|
          candidate == :default || is_match?(test, candidate, s.matching_expr, scope)
        }
      }
      if selected
        evaluate(selected.value_expr, scope)
      else
        nil
      end
    end
  end

  # Evaluates Puppet DSL `if`
  def eval_IfExpression o, scope
    with_guarded_scope(scope) do
      if is_true?(evaluate(o.test, scope))
        evaluate(o.then_expr, scope)
      else
        evaluate(o.else_expr, scope)
      end
    end
  end

  # Evaluates Puppet DSL `unless`
  def eval_UnlessExpression o, scope
    with_guarded_scope(scope) do
      unless is_true?(evaluate(o.test, scope))
        evaluate(o.then_expr, scope)
      else
        evaluate(o.else_expr, scope)
      end
    end
  end

  # Evaluates a variable (getting its value)
  # The evaluator is lenient; any expression producing a String is used as a name
  # of a variable.
  #
  def eval_VariableExpression o, scope
    # Evaluator is not too fussy about what constitutes a name as long as the result
    # is a String and a valid variable name
    #
    name = evaluate(o.expr, scope)

    # Should be caught by validation, but make this explicit here as well, or mysterious evaluation issues
    # may occur.
    case name
    when String
    when Numeric
    else
      fail(Issues::ILLEGAL_VARIABLE_EXPRESSION, o.expr)
    end
    # TODO: Check for valid variable name (Task for validator)
    # TODO: semantics of undefined variable in scope, this just returns what scope does == value or nil
    get_variable_value(name, o, scope)
  end

  # Evaluates double quoted strings that may contain interpolation
  #
  def eval_ConcatenatedString o, scope
    o.segments.collect {|expr| evaluate(expr, scope).to_s}.join
  end


  # If the wrapped expression is a QualifiedName, it is taken as the name of a variable in scope.
  # Note that this is different from the 3.x implementation, where an initial qualified name
  # is accepted. (e.g. `"---${var + 1}---"` is legal. This implementation requires such concrete
  # syntax to be expressed in a model as `(TextExpression (+ (Variable var) 1)` - i.e. moving the decision to
  # the parser.
  #
  # Semantics; the result of an expression is turned into a string, nil is silently transformed to empty
  # string.
  # @return [String] the interpolated result
  #
  def eval_TextExpression o, scope
    if o.expr.is_a?(Puppet::Pops::Model::QualifiedName)
      # TODO: formalize, when scope returns nil, vs error
      get_variable_value(o.expr.value, o, scope).to_s
    else
      # TODO: This is not very good as it forces the to_s to apply to all kind of results
      # It should call a polymorph method to allow to_s to be applied in general, and possible some other
      # to string formatter for other values (like PType Objects).
      #
      evaluate(o.expr, scope).to_s
    end
  end

  # Produces concatenation / merge of x and y.
  #
  # When x is an Array, y of type produces:
  #
  # * Array => concatenation `[1,2], [3,4] => [1,2,3,4]`
  # * Hash => concatenation of hash as array `[key, value, key, value, ...]`
  # * any other => concatenation of single value
  #
  # When x is a Hash, y of type produces:
  #
  # * Array => merge of array interpreted as `[key, value, key, value,...]`
  # * Hash => a merge, where entries in `y` overrides
  # * any other => error
  #
  # When x is something else, wrap it in an array first.
  #
  # When x is nil, an empty array is used instead.
  #
  # @note to concatenate an Array, nest the array - i.e. `[1,2], [[2,3]]`
  #
  # @overload concatenate(obj_x, obj_y)
  #   @param obj_x [Object] object to wrap in an array and concatenate to; see other overloaded methods for return type
  #   @param ary_y [Object] array to concatenate at end of `ary_x`
  #   @return [Object] wraps obj_x in array before using other overloaded option based on type of obj_y
  # @overload concatenate(ary_x, ary_y)
  #   @param ary_x [Array] array to concatenate to
  #   @param ary_y [Array] array to concatenate at end of `ary_x`
  #   @return [Array] new array with `ary_x` + `ary_y`
  # @overload concatenate(ary_x, hsh_y)
  #   @param ary_x [Array] array to concatenate to
  #   @param hsh_y [Hash] converted to array form, and concatenated to array
  #   @return [Array] new array with `ary_x` + `hsh_y` converted to array
  # @overload concatenate (ary_x, obj_y)
  #   @param ary_x [Array] array to concatenate to
  #   @param obj_y [Object] non array or hash object to add to array
  #   @return [Array] new array with `ary_x` + `obj_y` added as last entry
  # @overload concatenate(hsh_x, ary_y)
  #   @param hsh_x [Hash] the hash to merge with
  #   @param ary_y [Array] array interpreted as even numbered sequence of key, value merged with `hsh_x`
  #   @return [Hash] new hash with `hsh_x` merged with `ary_y` interpreted as hash in array form
  # @overload concatenate(hsh_x, hsh_y)
  #   @param hsh_x [Hash] the hash to merge to
  #   @param hsh_y [Hash] hash merged with `hsh_x`
  #   @return [Hash] new hash with `hsh_x` merged with `hsh_y`
  # @raise [ArgumentError] when `xxx_x` is neither an Array nor a Hash
  # @raise [ArgumentError] when `xxx_x` is a Hash, and `xxx_y` is neither Array nor Hash.
  #
  def concatenate(x, y)
    x = [x] unless x.is_a?(Array) || x.is_a?(Hash)
    case x
    when Array
      y = case y
      when Array then y
      when Hash  then y.to_a
      else
        [y]
      end
      x + y # new array with concatenation
    when Hash
      y = case y
      when Hash then y
      when Array
        # Hash[[a, 1, b, 2]] => {}
        # Hash[a,1,b,2] => {a => 1, b => 2}
        # Hash[[a,1], [b,2]] => {[a,1] => [b,2]}
        # Hash[[[a,1], [b,2]]] => {a => 1, b => 2}
        # Use type calcultor to determine if array is Array[Array[?]], and if so use second form
        # of call
        t = @@type_calculator.infer(y)
        if t.element_type.is_a? Puppet::Pops::Types::PArrayType
          Hash[y]
        else
          Hash[*y]
        end
      else
        raise ArgumentError.new("Can only append Array or Hash to a Hash")
      end
      x.merge y # new hash with overwrite
    else
      raise ArgumentError.new("Can only append to an Array or a Hash.")
    end
  end

  # Produces the result x \ y (set difference)
  # When `x` is an Array, `y` is transformed to an array and then all matching elements removed from x.
  # When `x` is a Hash, all contained keys are removed from x as listed in `y` if it is an Array, or all its keys if it is a Hash.
  # The difference is returned. The given `x` and `y` are not modified by this operation.
  # @raise [ArgumentError] when `x` is neither an Array nor a Hash
  #
  def delete(x, y)
    result = x.dup
    case x
    when Array
      y = case y
      when Array then y
      when Hash then y.to_a
      else
        [y]
      end
      y.each {|e| result.delete(e) }
    when Hash
      y = case y
      when Array then y
      when Hash then y.keys
      else
        [y]
      end
      y.each {|e| result.delete(e) }
    else
      raise ArgumentError.new("Can only delete from an Array or Hash.")
    end
    result
  end

  # Implementation of case option matching.
  #
  # This is the type of matching performed in a case option, using == for every type
  # of value except regular expression where a match is performed.
  # @todo there are implementation issues left to deal with (see source)
  #
  def is_match? left, right, o, scope
    # TODO: deal with TypeError
    # TODO: match when left is a Number, or something strange
    # TODO: solution should be used in MatchExpression
    if right.is_a?(Regexp)
      matched = right.match(left)
      set_match_data(matched, o, scope) # creates or clears ephemeral
      !!matched # convert to boolean
    else
      left == right
    end
  end

  def with_guarded_scope(scope)
    scope_memo = get_scope_nesting_level(scope)
    begin
      yield
    ensure
      set_scope_nesting_level(scope, scope_memo)
    end
  end

  # Translates data type name to instance of a data type.
  #
  # Maps an object to an instance of RGen::ECore::EDataType - i.e. returns
  # an enum, `EString`, `EInt`, `EFloat`, or `EBoolean`. The default (if nil) is `EString`.
  # If an instance of EEnum is passed, a new Enum datatype is created named after the
  # attributes (e.g. fooEnumValues) unless the enum is already named. This named enum can not
  # be accessed and reused, but it is of value when debugging that it has a name related to
  # the attribute).
  #
  # @param o [String, RGen::Ecore::EDataType, nil] reference to, or real data type
  # @param attribute_name [String] the name of the attribute having data type given by `o`
  # @param scope [Object] the runtime specific scope where this instruction is evaluated
  # @return [RGen::ECore::EDataType] a datatype for `o` with name `attribute_name`, being one of
  #   a named enum, `EString`, `EInt`, `EFloat`, or `EBoolean`. The default (if nil) is `EString`.
  #
  # @todo the scope should not be part of the signature; it is currently used to get to a type creator where
  #   an enum can be created. It should instead use an adapter to find the type creator associated
  #   with the actual object (i.e. create the datatype in the same package as it's container).
  #   This is not known by the scope.
  #
  def datatype_reference(o, attribute_name, scope)
    case o
    when RGen::ECore::EEnum
      o.ePackage = package
      # anonymous enums are named after the attribute
      # This is slightly problematic as the names are stored as constants in the
      # module, and may thus overwrite a constant (which does not really matter) since
      # the constant gets erased anyway by the type creator
      # after having been associated with the created object/class.
      #
      o.name = attribute_name + "EnumValues" unless o.name
      scope.top_scope.type_creator.create_enum o
    when RGen::ECore::EDataType
      # Already resolved to a data type
      o
    when 'String'
      RGen::ECore::EString
    when 'Integer'
      RGen::ECore::EInt
    when 'Float'
      RGen::ECore::EFloat
    when 'Boolean'
      RGen::ECore::EBoolean
    when NilClass
      # Default, if no expression given
      RGen::ECore::EString
    else
      nil
    end
  end
end
