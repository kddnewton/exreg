# Exreg

A Unicode regular expression library written in Ruby.

## Usage

```ruby
require "exreg"

pattern = Exreg::Pattern.new("abc")
pattern.match?("xxx abc yyy zzz") # => true
```

## Features

`Exreg` implements almost all of the same features as the Unicode subset of [Onigmo](https://github.com/k-takata/Onigmo/blob/master/doc/RE), the regular expression library used in Ruby. This includes everything except the following major features:

* Full case folding (only common case folding is supported)
* Word boundaries and non-word boundaries (`\b`, `\B`)
* Look-ahead and look-behind assertions (`(?=subexp)`, `(?!subexp)`, `(?<=subexp)`, `(?<!subexp)`)
* Backreferences (`\n`, `\k<n>`, etc.)

It also includes these less-commonly used features:

* Extended form (`x` option)
* Extended grapheme cluster (`\X`)
* Keep expression (`\K`)
* The cursor anchor (`\G`)
* Conditional expressions (`(?(cond)yes-subexp)`, `(?(cond)yes-subexp|no-subexp)`)
* Absence operator (`(?~subexp)`)
* Backreference with recursion level (`\k<n+level>`)
* Subexpression calls (`\g<n>`)

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/kddnewton/exreg.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
