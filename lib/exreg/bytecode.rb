# frozen_string_literal: true

module Exreg
  # This module is responsible for the bytecode representation of the regular
  # expression. It has classes to compile a DFA into a bytecode and to execute
  # the bytecode.
  module Bytecode
    module Insn
      # Immediately fail the match.
      class Failure
        def disasm
          "failure"
        end
      end

      # Fail the match if there are no more bytes to read.
      class FailLength
        def disasm
          "fail-length"
        end
      end

      # Immediately succeed the match.
      class Success
        def disasm
          "success"
        end
      end

      # Unconditionally jump to a given address.
      class Jump
        attr_reader :address

        def initialize(address:)
          @address = address
        end

        def disasm
          "%-16s %d" % ["jump", address]
        end

        def deconstruct_keys(keys)
          { address: address }
        end
      end

      # Jump to a given address if the current byte is equal to a given byte.
      class JumpByte
        attr_reader :byte, :address

        def initialize(byte:, address:)
          @byte = byte
          @address = address
        end

        def disasm
          "%-16s %d, %d" % ["jump-byte", byte, address]
        end

        def deconstruct_keys(keys)
          { byte:, address: address }
        end
      end

      # Jump to a given address if the current byte matches a given bitmask.
      class JumpMask
        attr_reader :mask, :address

        def initialize(mask:, address:)
          @mask = mask
          @address = address
        end

        def disasm
          "%-16s %d, %d" % ["jump-mask", mask, address]
        end

        def deconstruct_keys(keys)
          { mask:, address: address }
        end
      end

      # Jump to a given address if the current byte is within a given range.
      class JumpRange
        attr_reader :minimum, :maximum, :address

        def initialize(minimum:, maximum:, address:)
          @minimum = minimum
          @maximum = maximum
          @address = address
        end

        def disasm
          "%-16s %d, %d, %d" % ["jump-range", minimum, maximum, address]
        end

        def deconstruct_keys(keys)
          { minimum: minimum, maximum: maximum, address: address }
        end
      end
    end

    # This compiler converts a DFA into its equivalent bytecode.
    class Compiler
      attr_reader :insns, :labels

      def initialize
        @insns = []
        @labels = {}
      end

      def emit(insn)
        insns << insn
      end

      def label(value)
        labels[value] = insns.size
      end

      def label_for(state, index = :start)
        :"state_#{state}_#{index}"
      end

      def compile(automaton)
        automaton.states.each do |state|
          label(label_for(state))

          if automaton.final?(state)
            emit(Insn::Success.new)
            next
          else
            emit(Insn::FailLength.new)
          end

          automaton.transitions[state].each_with_index do |(next_state, transition), index|
            label(label_for(state, index))
            next_label = label_for(next_state)

            case transition
            in Automaton::AnyTransition
              emit(Insn::Jump.new(address: next_label))
            in Automaton::CharacterTransition[value:]
              emit(Insn::JumpByte.new(byte: value, address: next_label))
            in Automaton::MaskTransition[value:]
              emit(Insn::JumpMask.new(mask: value, address: next_label))
            in Automaton::RangeTransition[from:, to:]
              emit(Insn::JumpRange.new(minimum: from, maximum: to, address: next_label))
            end
          end

          emit(Insn::Failure.new)
        end

        insns.map do |insn|
          case insn
          in Insn::Failure | Insn::FailLength | Insn::Success
            insn
          in Insn::Jump[address:]
            Insn::Jump.new(address: labels[address])
          in Insn::JumpByte[byte:, address:]
            Insn::JumpByte.new(byte: byte, address: labels[address])
          in Insn::JumpMask[mask:, address:]
            Insn::JumpMask.new(mask: mask, address: labels[address])
          in Insn::JumpRange[minimum:, maximum:, address:]
            Insn::JumpRange.new(minimum: minimum, maximum: maximum, address: labels[address])
          end
        end
      end
    end

    # This class is a bytecode interpreter.
    class Machine
      attr_reader :insns

      def initialize(insns)
        @insns = insns
      end

      def disasm
        insns.each_with_index do |insn, index|
          puts "%03d %s" % [index, insn.disasm]
        end
      end

      def match?(string)
        pc = 0

        index = 0
        bytes = string.bytes

        loop do
          case insns[pc]
          in Insn::Failure
            return false
          in Insn::FailLength
            return false if index == bytes.length
            pc += 1
          in Insn::Success
            return true
          in Insn::Jump[address:]
            pc = address
            index += 1
          in Insn::JumpByte[byte:, address:]
            if bytes[index] == byte
              pc = address
              index += 1
            else
              pc += 1
            end
          in Insn::JumpMask[mask:, address:]
            if (bytes[index] & mask) == mask
              pc = address
              index += 1
            else
              pc += 1
            end
          in Insn::JumpRange[minimum:, maximum:, address:]
            if bytes[index] >= minimum && bytes[index] <= maximum
              pc = address
              index += 1
            else
              pc += 1
            end
          end
        end
      end
    end

    def self.compile(automaton)
      Machine.new(Compiler.new.compile(automaton))
    end
  end
end
