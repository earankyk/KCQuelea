Quelea
======

A Haskell library for declarative programming over eventually consistent stores ([Cassandra](http://cassandra.apache.org/) to be precise).

Requirements
------------
* A Z3 installation
  * **Use the included custom Z3 version.**. Installation instructions can be found under Z3/README.
* Glasgow Haskell Compiler (GHC) version 7.6.3+ - [https://www.haskell.org/ghc/](https://www.haskell.org/ghc/)
* Z3 package - Haskell bindings for Z3 theorem prover
  * **Use the included custom z3 package.** To install, "cabal install" in the included Z3_Haskell submodule. This version includes bindings not found in the [z3 package on hackage](https://hackage.haskell.org/package/z3).
* Cassandra-cql package - Haskell bindings for Cassandra CQL
  * **Use the included custom z3 package.** To install, "cabal install" in the included cassandra-cql submodule. This version uses CQL binary protocol v2.
* Datastax Cassandra 2.0.6 - [http://www.datastax.com/dev/blog/cassandra-2-0-6](http://www.datastax.com/dev/blog/cassandra-2-0-6)
