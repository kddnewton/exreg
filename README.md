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
* Other
  * [DFA minimization](https://en.wikipedia.org/wiki/DFA_minimization)
  * [NFA minimization](https://www.researchgate.net/publication/3045459_On_the_State_Minimization_of_Nondeterministic_Finite_Automata)
  * [Lazy DFAs](http://wwwmayr.informatik.tu-muenchen.de/lehre/2014WS/afs/2014-11-14.pdf)
  * [TruffleRuby regexp analyzer](https://github.com/Shopify/truffleruby-utils/tree/master/regexp-analyzer)
  * [Practical Experience with TRegex and Ruby](https://www.youtube.com/watch?v=0a73au-sbTM)
  * [Optimizing based on source encoding in graal](https://github.com/oracle/graal/pull/3806)
