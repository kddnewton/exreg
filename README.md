# Exreg

[![Build Status](https://github.com/kddnewton/exreg/workflows/Main/badge.svg)](https://github.com/kddnewton/exreg/actions)
[![Gem Version](https://img.shields.io/gem/v/exreg.svg)](https://rubygems.org/gems/exreg)

Exreg is a regular expression engine built in Ruby.

The current regular expression engine in Ruby is [Onigmo](https://github.com/k-takata/Onigmo), a full-feature regular expression engine written in C. Its strategy for matching strings is to compile its regular expressions into a bytecode that models a non-deterministic state machine. For most cases this works well, but for some it can result in [catastrophic backtracking](https://www.regular-expressions.info/catastrophic.html).

Backtracking is unavoidable when certain features are used in regular expressions (e.g., backreferences) because the power of the regular expression exceeds the power of a finite state automata. However, when those features are not used, other strategies for matching the input string can be employed. Namely, the state machine can be fully determinized at compile-time (ahead-of-time determinization) or lazily determinized at runtime (just-in-time determinization). Exreg provides the ability to take either of these approaches.

## Usage

```ruby
require "exreg"

pattern = Exreg::Pattern.new("abc")
pattern.match?("xxx abc yyy zzz") # => true
```

### Basic functionality

* `\` escape
* `|` alternation
* `(...)` grouping (not capturing yet)
* `[...]` character class

### Character types

* `.` any character
* `\w` word character (`Letter | Mark | Number | Connector_Punctuation`)
* `\s` whitespace character (`[\x09-\x0D] | \x85 | Line_Separator | Paragraph_Separator | Space_Separator`)
* `\d` decimal digit character (`Decimal_Number`)
* `\h` hexadecimal digit character (`[0-9a-fA-f]`)
* `\p{property-name}` matches unicode properties

### Quantifiers

* `?` 0 or 1 times
* `*` 0 or more times
* `+` 1 or more times
* `{n,m}` at least n but no more than m times
* `{n,}` at least n times
* `{,n}` at least 0 but no more than n times (`{0,n}`)
* `{n}` n times

### Character classes

* `x-y` range from x to y

### POSIX brackets

* `[:alnum:]` (`Letter | Mark | Decimal_Number`)
* `[:alpha:]` (`Letter | Mark`)
* `[:ascii:]` (`[\x00-\x7F]`)
* `[:blank:]` (`Space_Separator | \x09`)
* `[:cntrl:]` (`Control | Format | Unassigned | Private_Use | Surrogate`)
* `[:digit:]` (`Decimal_Number`)
* `[:graph:]` (`[:^space:] && ^Control && ^Unassigned && ^Surrogate`)
* `[:lower:]` (`Lowercase_Letter`)
* `[:print:]` (`[:graph:] | Space_Separator`)
* `[:punct:]` (`Connector_Punctuation | Dash_Punctuation | Close_Punctuation | Final_Punctuation | Initial_Punctuation | Other_Punctuation | Open_Punctuation | 0024 | 002B | 003C | 003D | 003E | 005E | 0060 | 007C | 007E`)
* `[:space:]` (`Space_Separator | Line_Separator | Paragraph_Separator | 0009 | 000A | 000B | 000C | 000D | 0085`)
* `[:upper:]` (`Uppercase_Letter`)
* `[:xdigit:]` (`0030 - 0039 | 0041 - 0046 | 0061 - 0066`)
* `[:word:]` (`Letter | Mark | Decimal_Number | Connector_Punctuation`)

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/kddnewton/exreg.

To begin contributing, first clone the repository. Then you'll need to generate the unicode character sets for each of the properties we support by deriving them from the unicode source for your version of Ruby by running `bundle exec rake`. This will also run the tests.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
