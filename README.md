# TODO

## Hard (impossible?) to implement in a DFA

* Non-greedy repetition (`*?`, `+?`)
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
* Capturing

## Other work

* DFA minimization
* NFA with lazy DFA transformation
* Recheck algorithm for finding ReDoS vulnerabilities
* Much more documentation

# Links

## Implementations

* [Irregexp](https://blog.chromium.org/2009/02/irregexp-google-chromes-new-regexp.html)
* [.NET](https://docs.microsoft.com/en-us/dotnet/standard/base-types/details-of-regular-expression-behavior)
* [one-more-re-nightmare](https://github.com/telekons/one-more-re-nightmare)
* [Python](https://github.com/python/cpython/blob/main/Lib/re/__init__.py)
* [RE2](https://github.com/google/re2)
* [Recheck](https://makenowjust-labs.github.io/recheck/docs/internals/background/)
* [Ruby](https://github.com/k-takata/Onigmo)
* [Rust](https://github.com/rust-lang/regex) ([PR](https://github.com/rust-lang/regex/pull/164))
* [TCL](https://github.com/garyhouston/hsrex)
* V8
  * [Tier up](https://v8.dev/blog/regexp-tier-up)
  * [Deterministic](https://v8.dev/blog/non-backtracking-regexp)

## Various papers, blog posts, and articles

* [A Closer Look at TDFA](https://arxiv.org/abs/2206.01398)
* [NFAs with Tagged Transitions, their Conversion to Deterministic Automata and Application to Regular Expressions (2000)](https://laurikari.net/ville/spire2000-tnfa.pdf)
* [Static Detection of DoS Vulnerabilities in Programs that use Regular Expressions (2017)](https://arxiv.org/abs/1701.04045)
* [On the Impact and Defeat of Regular Expression Denial of Service (2020)](https://vtechworks.lib.vt.edu/handle/10919/98593)
* [Russ Cox series](https://swtch.com/~rsc/regexp/regexp1.html)
* [A DFA for submatch extraction](https://nitely.github.io/assets/jan_2020_dfa_submatches_extraction.pdf)
* [Compiling Nondeterministic Transducers to Deterministic Streaming Transducers](https://di.ku.dk/kmc/documents/ghrst2016-0-paper.pdf)
* [Translating Regular Expression Matching into Transducers](https://ieeexplore.ieee.org/document/5715276)
* [DFA minimization](https://en.wikipedia.org/wiki/DFA_minimization)
* [NFA minimization](https://www.researchgate.net/publication/3045459_On_the_State_Minimization_of_Nondeterministic_Finite_Automata)
* [Lazy DFAs](http://wwwmayr.informatik.tu-muenchen.de/lehre/2014WS/afs/2014-11-14.pdf)
* [TruffleRuby regexp analyzer](https://github.com/Shopify/truffleruby-utils/tree/master/regexp-analyzer)
* [Practical Experience with TRegex and Ruby](https://www.youtube.com/watch?v=0a73au-sbTM)
* [Optimizing based on source encoding in graal](https://github.com/oracle/graal/pull/3806)
* [Regular Expressions, Text Normalization, Edit Distance](https://web.stanford.edu/~jurafsky/slp3/2.pdf)

## Ruby

* [RubyConf 2013: Beneath The Surface: Harnessing The True Power of Regular Expressions in Ruby](https://www.youtube.com/watch?v=JfwS4ibJFDw)
* [Exploring Ruby's Regular Expression Algorithm](https://patshaughnessy.net/2012/4/3/exploring-rubys-regular-expression-algorithm)
