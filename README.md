# TODO

## Hard (impossible?) to implement in a DFA

* Non-greedy repetition (`*?`, `+?`)
* Capturing
* Subexpression calls
* Assertions (lookahead/lookbehind)

## Possible and should be implemented

* Anchors
* Character property inversion
* Character set inversion
* Character set composition
* Case-insensitive mode
* Multi-line mode
* Free-spacing mode

# Links

* Papers
  * [NFAs with Tagged Transitions, their Conversion to Deterministic Automata and Application to Regular Expressions (2000)](https://laurikari.net/ville/spire2000-tnfa.pdf)
  * [Static Detection of DoS Vulnerabilities in Programs that use Regular Expressions (2017)](https://arxiv.org/abs/1701.04045)
  * [On the Impact and Defeat of Regular Expression Denial of Service (2020)](https://vtechworks.lib.vt.edu/handle/10919/98593)
* Implementations
  * [.NET](https://docs.microsoft.com/en-us/dotnet/standard/base-types/details-of-regular-expression-behavior)
  * [Recheck](https://makenowjust-labs.github.io/recheck/docs/internals/background/)
  * [Rust](https://github.com/rust-lang/regex/blob/master/HACKING.md)
    * [PR for lazy DFAs](https://github.com/rust-lang/regex/pull/164)
