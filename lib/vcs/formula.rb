# frozen_string_literal: true

require 'strscan'
require 'date'

module Vcs
  # A bounded arithmetic interpreter. Never executes Ruby, JavaScript or shell code.
  class Formula
    Error = Class.new(StandardError)
    def initialize(source, values: {}, fields: {}, today: Date.current)
      raise Error, 'Formula is too long' if source.bytesize > 4000
      @values, @fields, @today = values, fields, today
      scanner = StringScanner.new(source)
      @tokens = []
      until scanner.eos?
        next if scanner.scan(/\s+/)
        token = scanner.scan(/\{\{[^{}]+\}\}|\d+(?:\.\d+)?|[a-z_]+|"[ymd]"|'[ymd]'|[+\-*\/^(),]/i)
        raise Error, 'Unsupported formula syntax' unless token
        @tokens << token
      end
      @position = 0
      @depth = 0
    end

    def call
      result = expression
      raise Error, 'Unexpected formula input' if peek
      raise Error, 'Formula result is not finite' if result.is_a?(Numeric) && !result.finite?
      result
    rescue ZeroDivisionError, TypeError, ArgumentError, RangeError, NoMethodError => e
      raise Error, "Invalid formula: #{e.message}"
    end

    private

    def peek = @tokens[@position]
    def take
      token = peek
      @position += 1
      token
    end
    def expect(token)
      raise Error, "Expected #{token}" unless take == token
    end

    def expression(min_precedence = 0)
      @depth += 1
      raise Error, 'Formula is too deeply nested' if @depth > 64
      left = primary
      priorities = { '+' => 1, '-' => 1, '*' => 2, '/' => 2, '^' => 3 }
      while (precedence = priorities[peek]) && precedence >= min_precedence
        op = take
        right = expression(precedence + (op == '^' ? 0 : 1))
        left = calculate(left, op, right)
      end
      left
    ensure
      @depth -= 1
    end

    def calculate(left, op, right)
      case op
      when '+' then left + right
      when '-' then left - right
      when '*' then left * right
      when '/' then left / Float(right)
      when '^'
        raise Error, 'Exponent outside supported range' if right.abs > 100
        left ** right
      end
    end

    def primary
      token = take
      raise Error, 'Incomplete formula' unless token
      case token
      when '(' then expression.tap { expect(')') }
      when '+' then primary
      when '-' then -primary
      when /\A\d/ then Float(token)
      when /\A\{\{/
        uuid = token[2...-2]
        field = @fields[uuid] || {}
        value = @values[uuid]
        if field['type'] == 'date'
          Date.iso8601(value.to_s.first(10))
        else
          Float(value.presence || 0)
        end
      when /\A["']/ then token[1]
      else
        expect('(')
        args = []
        unless peek == ')'
          args << expression
          while peek == ','
            take
            args << expression
          end
        end
        expect(')')
        function(token.downcase, args)
      end
    end

    def function(name, args)
      case [name, args.size]
      when ['today', 0] then @today
      when ['abs', 1] then args[0].abs
      when ['round', 1] then args[0].round
      when ['round', 2]
        raise Error, 'Rounding precision outside supported range' unless (-10..10).cover?(args[1])
        args[0].round(args[1].to_i)
      when ['datedif', 3]
        start_date, end_date, unit = args
        raise Error, 'datedif expects dates' unless start_date.is_a?(Date) && end_date.is_a?(Date)
        case unit
        when 'd' then (end_date - start_date).to_i
        when 'm' then (end_date.year - start_date.year) * 12 + end_date.month - start_date.month - (end_date.day < start_date.day ? 1 : 0)
        when 'y' then end_date.year - start_date.year - (([end_date.month, end_date.day] <=> [start_date.month, start_date.day]) == -1 ? 1 : 0)
        else raise Error, 'Unsupported datedif unit' end
      else raise Error, 'Unsupported function or argument count'
      end
    end
  end
end
