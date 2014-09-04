# -*- encoding: utf-8 -*-

require 'strscan'
require 'hexapdf/error'
require 'hexapdf/pdf/reference'

module HexaPDF
  module PDF

    # Tokenizes the content of an IO object following the PDF rules.
    #
    # This class is used by Parser to do the low-level work and it is not intended to be used
    # otherwise.
    #
    # See: PDF1.7 s7.2
    class Tokenizer

      # Represents a keyword in a PDF file.
      class Token < String; end

      # This object is returned when there are no more tokens to read.
      NO_MORE_TOKENS = Object.new

      # Characters defined as whitespace.
      #
      # See: PDF1.7 s7.2.2
      WHITESPACE = "\0\t\n\f\r "

      # The IO object from the tokens are read.
      attr_reader :io

      # Create a new tokenizer.
      def initialize(io)
        @io = io
        @ss = StringScanner.new(''.force_encoding('BINARY'))
        self.pos = 0
      end

      # The current position of the tokenizer inside in the IO object.
      #
      # Note that this position might be different from +io.pos+ since the latter could have been
      # changed somewhere else.
      def pos
        @original_pos + @ss.pos
      end

      # Set the position at which the next token should be read.
      #
      # Note that this does **not** set +io.pos+ directly (at the moment of invocation)!
      def pos=(pos)
        @original_pos = pos
        @next_read_pos = pos
        @ss.string.clear
        @ss.reset
      end

      # Return the token at the current position and advance the scan pointer.
      def next_token
        tok = parse_token

        if tok.kind_of?(Integer) # Handle object references, see PDF1.7 s7.3.10
          prepare_string_scanner
          save_pos = @ss.pos
          if (tok2 = parse_token) && tok2.kind_of?(Integer) &&
              (tok3 = parse_token) && tok3.kind_of?(Token) && tok3 == 'R'
            tok = Reference.new(tok, tok2)
          else
            @ss.pos = save_pos
          end
        end

        tok
      end

      # Return the next token but do not advance the scan pointer.
      def peek_token
        pos = @ss.pos
        tok = next_token
        @ss.pos = pos
        tok
      end

      # Read the byte at the current position and advance the scan pointer.
      def next_byte
        prepare_string_scanner if @ss.eos?
        @ss.get_byte
      end

      # Read the cross-reference subsection entry at the current position and advance the scan
      # pointer.
      #
      # See: PDF1.7 7.5.4
      def next_xref_entry
        prepare_string_scanner if @ss.rest_size < 20
        unless @ss.scan(/(\d{10}) (\d{5}) ([nf])( \r| \n|\r\n)/)
          raise HexaPDF::MalformedPDFError.new("Invalid cross-reference subsection entry", pos)
        end
        [@ss[1].to_i, @ss[2].to_i, @ss[3]]
      end

      # Skip all whitespace (see WHITESPACE) at the current position.
      def skip_whitespace
        prepare_string_scanner
        @ss.skip(WHITESPACE_MULTI_RE)
      end

      private

      # Characters defined as delimiters.
      # See: PDF1.7 s7.2.2
      DELIMITER = "()<>{}/[]%"

      WHITESPACE_SINGLE_RE = /[#{WHITESPACE}]/
      WHITESPACE_MULTI_RE = /[#{WHITESPACE}]*/
      WHITESPACE_OR_DELIMITER_RE = /(?=[#{Regexp.escape(WHITESPACE)}#{Regexp.escape(DELIMITER)}])/


      # Parse the single token at the current position.
      #
      # Comments and a run of whitespace characters are ignored. The value +NO_MORE_TOKENS+ is
      # returned if there are no more tokens available.
      def parse_token
        prepare_string_scanner
        case byte = @ss.get_byte
        when WHITESPACE_SINGLE_RE
          @ss.skip(WHITESPACE_MULTI_RE)
          parse_token
        when '/'
          parse_name
        when '('
          parse_literal_string
        when '<'
          if @ss.peek(1) != '<'
            parse_hex_string
          else
            @ss.pos += 1
            Token.new('<<'.force_encoding('BINARY'))
          end
        when '>'
          unless @ss.get_byte == '>'
            raise HexaPDF::MalformedPDFError.new("Delimiter '>' found at invalid position", pos)
          end
          Token.new('>>'.force_encoding('BINARY'))
        when '[', ']', '{', '}'
          Token.new(byte)
        when '%' # start of comment, until end of line
          while !@ss.skip_until(/(?=[\r\n])/)
            return NO_MORE_TOKENS if !prepare_string_scanner
          end
          parse_token
        when nil # we reached the end of the file
          NO_MORE_TOKENS
        else # everything else consisting of regular characters
          byte << (scan_until_with_eof_check(WHITESPACE_OR_DELIMITER_RE) || @ss.scan(/.*/))
          convert_keyword(byte)
        end
      end

      # Convert the give keyword to a PDF boolean, integer or float object, if possible.
      #
      # See: PDF1.7 s7.3.2, s7.3.3, s7.3.9
      def convert_keyword(str)
        case str
        when 'true'
          true
        when 'false'
          false
        when 'null'
          nil
        when /\A[+-]?\d+\z/
          Integer(str)
        when /\A[+-]?(?:\d+\.?\d*|\.\d+)\z/
          str << '0' if str[-1] == '.'
          Float(str)
        else
          Token.new(str)
        end
      end

      LITERAL_STRING_ESCAPE_MAP = {
        'n' => "\n",
        'r' => "\r",
        't' => "\t",
        'b' => "\b",
        'f' => "\f",
        '(' => "(",
        ')' => ")",
        '\\' => "\\"
      }

      # Parse the literal string at the current position. The initial '(' needs to be scanned
      # already.
      #
      # See: PDF1.7 s7.3.4.2
      def parse_literal_string
        str = "".force_encoding('BINARY')
        parentheses = 1

        while parentheses != 0
          data = scan_until_with_eof_check(/([()\\\r])/)
          unless data
            raise HexaPDF::MalformedPDFError.new("Unclosed literal string found", pos)
          end

          str << data
          prepare_string_scanner if @ss.eos?
          case @ss[1]
          when '(' then parentheses += 1
          when ')' then parentheses -= 1
          when "\r"
            str[-1] = "\n"
            @ss.pos += 1 if @ss.peek(1) == "\n"
          when '\\'
            str.slice!(-1, 1)
            byte = @ss.get_byte
            if data = LITERAL_STRING_ESCAPE_MAP[byte]
              str << data
            elsif byte == "\r" || byte == "\n"
              @ss.pos += 1 if byte == "\r" && @ss.peek(1) == "\n"
            elsif byte >= '0' && byte <= '7'
              byte += @ss.scan(/[0-7]{0,2}/)
              str << byte.oct.chr
            else
              str << byte
            end
          end
        end

        str.slice!(-1, 1) # remove last parsed closing parenthesis
        str
      end

      # Parse the hex string at the current position. The initial '#' needs to be scanned already.
      #
      # See: PDF1.7 s7.3.4.3
      def parse_hex_string
        data = scan_until_with_eof_check(/(?=>)/)
        unless data
          raise HexaPDF::MalformedPDFError.new("Unclosed hex string found", pos)
        end

        @ss.pos += 1
        data.tr!(WHITESPACE, "")
        [data].pack('H*')
      end

      # Parse the name at the current position. The initial '/' needs to be scanned already.
      #
      # See: PDF1.7 s7.3.5
      def parse_name
        str = scan_until_with_eof_check(WHITESPACE_OR_DELIMITER_RE) || @ss.scan(/.*/)
        str.gsub!(/#[A-Fa-f0-9]{2}/) {|m| m[1,2].hex.chr }
        str.to_sym
      end


      # Prepare the StringScanner by filling its string instance with enough bytes.
      #
      # Returns +true+ if the end of the underlying IO stream has not been reached, yet.
      def prepare_string_scanner
        @io.seek(@next_read_pos)
        return false if @io.eof?

        @ss << @io.read(1024)
        if @ss.pos > 1024 && @ss.string.length > 20480
          @ss.string.slice!(0, 1024)
          @ss.pos -= 1024
          @original_pos += 1024
        end
        @next_read_pos = @io.pos
        true
      end

      # Utility method for scanning until the given regular expression matches. If the match cannot
      # found at first, the string of the underlying StringScanner is extended and then the regexp
      # is tried again. This is done as long as needed.
      #
      # If the end of the file is reached in the process, +nil+ is returned. Otherwise the matched
      # string is returned.
      def scan_until_with_eof_check(re)
        while !(data = @ss.scan_until(re))
          return nil unless prepare_string_scanner
        end
        data
      end

    end

  end
end
