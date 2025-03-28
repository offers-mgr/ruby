# NEWS for Ruby 3.2.0

This document is a list of user-visible feature changes
since the **3.1.0** release, except for bug fixes.

Note that each entry is kept to a minimum, see links for details.

## Language changes

* Anonymous rest and keyword rest arguments can now be passed as
  arguments, instead of just used in method parameters.
  [[Feature #18351]]

    ```ruby
    def foo(*)
      bar(*)
    end
    def baz(**)
      quux(**)
    end
    ```

* A proc that accepts a single positional argument and keywords will
  no longer autosplat. [[Bug #18633]]

    ```ruby
    proc{|a, **k| a}.call([1, 2])
    # Ruby 3.1 and before
    # => 1
    # Ruby 3.2 and after
    # => [1, 2]
    ```

* Constant assignment evaluation order for constants set on explicit
  objects has been made consistent with single attribute assignment
  evaluation order. With this code:

    ```ruby
    foo::BAR = baz
    ```

    `foo` is now called before `baz`. Similarly, for multiple assignments
    to constants,  left-to-right evaluation order is used. With this
    code:

    ```ruby
    foo1::BAR1, foo2::BAR2 = baz1, baz2
    ```

    The following evaluation order is now used:

    1. `foo1`
    2. `foo2`
    3. `baz1`
    4. `baz2`

    [[Bug #15928]]

* "Find pattern" is no longer experimental.
  [[Feature #18585]]

* Methods taking a rest parameter (like `*args`) and wishing to delegate keyword
  arguments through `foo(*args)` must now be marked with `ruby2_keywords`
  (if not already the case). In other words, all methods wishing to delegate
  keyword arguments through `*args` must now be marked with `ruby2_keywords`,
  with no exception. This will make it easier to transition to other ways of
  delegation once a library can require Ruby 3+. Previously, the `ruby2_keywords`
  flag was kept if the receiving method took `*args`, but this was a bug and an
  inconsistency. A good technique to find the potentially-missing `ruby2_keywords`
  is to run the test suite, for where it fails find the last method which must
  receive keyword arguments, use `puts nil, caller, nil` there, and check each
  method/block on the call chain which must delegate keywords is correctly marked
  as `ruby2_keywords`. [[Bug #18625]] [[Bug #16466]]

    ```ruby
    def target(**kw)
    end

    # Accidentally worked without ruby2_keywords in Ruby 2.7-3.1, ruby2_keywords
    # needed in 3.2+. Just like (*args, **kwargs) or (...) would be needed on
    # both #foo and #bar when migrating away from ruby2_keywords.
    ruby2_keywords def bar(*args)
      target(*args)
    end

    ruby2_keywords def foo(*args)
      bar(*args)
    end

    foo(k: 1)
    ```

* `eval` and related methods are able to generate code coverage. Enabled using
  `Coverage.setup(:all)` or `Coverge.setup(eval: true)`. [[Feature #19008]]

* `Coverage.supported?(mode)` enables detection of what coverage modes are
  supported. [[Feature #19026]]

## Command line options

## Core classes updates

Note: We're only listing outstanding class updates.

* Fiber::Scheduler

    * Introduce `Fiber::Scheduler#io_select` for non-blocking IO.select.
      [[Feature #19060]]

* IO

    * Introduce IO#timeout= and IO#timeout which can cause
      IO::TimeoutError to be raised if a blocking operation exceeds the
      specified timeout. [[Feature #18630]]

        ```ruby
        STDIN.timeout = 1
        STDIN.read # => Blocking operation timed out! (IO::TimeoutError)
        ```

* UNIXSocket

    * Add support for UNIXSocket on Windows. Emulate anonymous sockets. Add
      support for File.socket? and File::Stat#socket? where possible.
      [[Feature #19135]]

* Class

    * Class#attached_object, which returns the object for which
      the receiver is the singleton class. Raises TypeError if the
      receiver is not a singleton class.
      [[Feature #12084]]

        ```ruby
        class Foo; end

        Foo.singleton_class.attached_object        #=> Foo
        Foo.new.singleton_class.attached_object    #=> #<Foo:0x000000010491a370>
        Foo.attached_object                        #=> TypeError: `Foo' is not a singleton class
        nil.singleton_class.attached_object        #=> TypeError: `NilClass' is not a singleton class
        ```

* Data

    * New core class to represent simple immutable value object. The class is
      similar to Struct and partially shares an implementation, but has more
      lean and strict API. [[Feature #16122]]

* Encoding

    * Encoding#replicate has been deprecated and will be removed in 3.3. [[Feature #18949]]
    * The dummy `Encoding::UTF_16` and `Encoding::UTF_32` encodings no longer
      try to dynamically guess the endian based on a byte order mark.
      Use `Encoding::UTF_16BE`/`UTF_16LE` and `Encoding::UTF_32BE`/`UTF_32LE` instead.
      This change speeds up getting the encoding of a String. [[Feature #18949]]

* Enumerator

    * Enumerator.product has been added.  Enumerator::Product is the implementation. [[Feature #18685]]

* Hash

    * Hash#shift now always returns nil if the hash is
      empty, instead of returning the default value or
      calling the default proc. [[Bug #16908]]

* Integer

    * Integer#ceildiv has been added. [[Feature #18809]]

* Kernel

    * Kernel#binding raises RuntimeError if called from a non-Ruby frame
      (such as a method defined in C). [[Bug #18487]]

* MatchData

    * MatchData#byteoffset has been added. [[Feature #13110]]
    * MatchData#deconstruct has been added. [[Feature #18821]]
    * MatchData#deconstruct_keys has been added. [[Feature #18821]]

* Module

    * Module.used_refinements has been added. [[Feature #14332]]
    * Module#refinements has been added. [[Feature #12737]]
    * Module#const_added has been added. [[Feature #17881]]
    * Module#undefined_instance_methods has been added. [[Feature #12655]]

* Proc

    * Proc#dup returns an instance of subclass. [[Bug #17545]]
    * Proc#parameters now accepts lambda keyword. [[Feature #15357]]

* Process
    * Added `RLIMIT_NPTS` constant to FreeBSD platform

* Regexp

    * Regexp.new now supports passing the regexp flags not only as an Integer,
      but also as a String.  Unknown flags raise ArgumentError.
      Otherwise, anything other than `true`, `false`, `nil` or Integer will be warned.
      [[Feature #18788]]

* Refinement

    * Refinement#refined_class has been added. [[Feature #12737]]

* RubyVM::AbstractSyntaxTree

    * Add `error_tolerant` option for `parse`, `parse_file` and `of`. [[Feature #19013]]
      With this option

        1. SyntaxError is suppressed
        2. AST is returned for invalid input
        3. `end` is complemented when a parser reachs to the end of input but `end` is insufficient
        4. `end` is treated as keyword based on indent

        ```ruby
        # Without error_tolerant option
        root = RubyVM::AbstractSyntaxTree.parse(<<~RUBY)
        def m
          a = 10
          if
        end
        RUBY
        # => <internal:ast>:33:in `parse': syntax error, unexpected `end' (SyntaxError)

        # With error_tolerant option
        root = RubyVM::AbstractSyntaxTree.parse(<<~RUBY, error_tolerant: true)
        def m
          a = 10
          if
        end
        RUBY
        p root # => #<RubyVM::AbstractSyntaxTree::Node:SCOPE@1:0-4:3>

        # `end` is treated as keyword based on indent
        root = RubyVM::AbstractSyntaxTree.parse(<<~RUBY, error_tolerant: true)
        module Z
          class Foo
            foo.
          end

          def bar
          end
        end
        RUBY
        p root.children[-1].children[-1].children[-1].children[-2..-1]
        # => [#<RubyVM::AbstractSyntaxTree::Node:CLASS@2:2-4:5>, #<RubyVM::AbstractSyntaxTree::Node:DEFN@6:2-7:5>]
        ```

    * Add `keep_tokens` option for `parse`, `parse_file` and `of`. Add `#tokens` and `#all_tokens`
      for RubyVM::AbstractSyntaxTree::Node [[Feature #19070]]

        ```ruby
        root = RubyVM::AbstractSyntaxTree.parse("x = 1 + 2", keep_tokens: true)
        root.tokens # => [[0, :tIDENTIFIER, "x", [1, 0, 1, 1]], [1, :tSP, " ", [1, 1, 1, 2]], ...]
        root.tokens.map{_1[2]}.join # => "x = 1 + 2"
        ```

* Set

    * Set is now available as a built-in class without the need for `require "set"`. [[Feature #16989]]
      It is currently autoloaded via the Set constant or a call to Enumerable#to_set.

* Socket

    * Added the following constants for supported platforms.
        * `SO_INCOMING_CPU`
        * `SO_INCOMING_NAPI_ID`
        * `SO_RTABLE`
        * `SO_SETFIB`
        * `SO_USER_COOKIE`
        * `TCP_KEEPALIVE`
        * `TCP_CONNECTION_INFO`

* String

    * String#byteindex and String#byterindex have been added. [[Feature #13110]]
    * Update Unicode to Version 14.0.0 and Emoji Version 14.0. [[Feature #18037]]
      (also applies to Regexp)
    * String#bytesplice has been added.  [[Feature #18598]]

* Struct

    * A Struct class can also be initialized with keyword arguments
      without `keyword_init: true` on Struct.new [[Feature #16806]]

* Time

    * Time#deconstruct_keys is added, allowing to use Time instances
      in pattern-matching expressions [[Feature #19071]]

* TracePoint

    * TracePoint#binding now returns `nil` for `c_call`/`c_return` TracePoints.
      [[Bug #18487]]
    * TracePoint#enable `target_thread` keyword argument now defaults to the
      current thread if `target` and `target_line` keyword arguments are not
      passed. [[Bug #16889]]

## Stdlib updates

* ERB

    * `-S` option is removed from `erb` command.

* FileUtils

    * Add FileUtils.ln_sr method and `relative:` option to FileUtils.ln_s.
      [[Feature #18925]]

* SyntaxSuggest

    * The feature of `syntax_suggest` formerly `dead_end` is integrated in Ruby.
      [[Feature #18159]]

*   The following default gems are updated.

    * RubyGems 3.4.0.dev
    * bigdecimal 3.1.2
    * bundler 2.4.0.dev
    * cgi 0.3.6
    * date 3.2.3
    * erb 4.0.1
    * error_highlight 0.5.1
    * etc 1.4.0
    * fiddle 1.1.1
    * io-console 0.5.11
    * io-nonblock 0.1.1
    * io-wait 0.3.0.pre
    * ipaddr 1.2.4
    * irb 1.5.1
    * json 2.6.2
    * logger 1.5.1
    * net-http 0.3.0
    * net-protocol 0.1.3
    * openssl 3.1.0.pre
    * ostruct 0.5.5
    * psych 5.0.0.dev
    * reline 0.3.1
    * securerandom 0.2.0
    * set 1.0.3
    * stringio 3.0.3
    * syntax_suggest 1.0.0
    * timeout 0.3.0

*   The following bundled gems are updated.

    * minitest 5.16.3
    * power_assert 2.0.2
    * test-unit 3.5.5
    * net-ftp 0.2.0
    * net-imap 0.3.1
    * net-pop 0.1.2
    * net-smtp 0.3.3
    * rbs 2.8.1
    * typeprof 0.21.3
    * debug 1.6.3

*   The following default gems are now bundled gems.

## Compatibility issues

Note: Excluding feature bug fixes.

### Removed constants

The following deprecated constants are removed.

* `Fixnum` and `Bignum` [[Feature #12005]]
* `Random::DEFAULT` [[Feature #17351]]
* `Struct::Group`
* `Struct::Passwd`

### Removed methods

The following deprecated methods are removed.

* `Dir.exists?` [[Feature #17391]]
* `File.exists?` [[Feature #17391]]
* `Kernel#=~` [[Feature #15231]]
* `Kernel#taint`, `Kernel#untaint`, `Kernel#tainted?`
  [[Feature #16131]]
* `Kernel#trust`, `Kernel#untrust`, `Kernel#untrusted?`
  [[Feature #16131]]

### Source code incompatiblity of extension libraries [[Bug #19100]]

* Extension libraries provide PRNG, subclasses of Random, need updates.
  See [PRNG update] below for more information.

## Stdlib compatibility issues

* Psych no longer bundles libyaml sources.
  And also Fiddle no longer bundles libffi sources.
  Users need to install the libyaml/libffi library themselves via the package
  manager like apt, yum, brew, etc.

    Psych and fiddle supported the static build with specific version of libyaml
    and libffi sources. You can build psych with libyaml-0.2.5 like this.

    ```bash
    $ ./configure --with-libyaml-source-dir=/path/to/libyaml-0.2.5
    ```

    And you can build fiddle with libffi-3.4.4 like this.

    ```bash
    $ ./configure --with-libffi-source-dir=/path/to/libffi-3.4.4
    ```

    [[Feature #18571]]

## C API updates

### Updated C APIs

The following APIs are updated.

* PRNG update

    `rb_random_interface_t` updated and versioned.
    Extension libraries which use this interface and built for older versions.
    Also `init_int32` function needs to be defined.

### Removed C APIs

The following deprecated APIs are removed.

* `rb_cData` variable.
* "taintedness" and "trustedness" functions. [[Feature #16131]]

## Implementation improvements

* Fixed several race conditions in Kernel#autoload. [[Bug #18782]]
* Cache invalidation for expressions referencing constants is now
  more fine-grained. `RubyVM.stat(:global_constant_state)` was
  removed because it was closely tied to the previous caching scheme
  where setting any constant invalidates all caches in the system.
  New keys, `:constant_cache_invalidations` and `:constant_cache_misses`,
  were introduced to help with use cases for `:global_constant_state`.
  [[Feature #18589]]

## JIT

### YJIT

* YJIT now supports both x86-64 and arm64/aarch64 CPUs on Linux, MacOS, BSD and other UNIX platforms.
    * This release brings support for Mac M1/M2, AWS Graviton and Raspberry Pi 4 ARM64 processors.
* Building YJIT requires Rust 1.58.0+. [[Feature #18481]]
    * In order to ensure that CRuby is built with YJIT, please install rustc >= 1.58.0 and
      run `./configure` with `--enable-yjit`.
    * Please reach out to the YJIT team should you run into any issues.
* Physical memory for JIT code is lazily allocated. Unlike Ruby 3.1,
  the RSS of a Ruby process is minimized because virtual memory pages
  allocated by `--yjit-exec-mem-size` will not be mapped to physical
  memory pages until actually utilized by JIT code.
* Introduce Code GC that frees all code pages when the memory consumption
  by JIT code reaches `--yjit-exec-mem-size`.
    * RubyVM::YJIT.runtime_stats returns Code GC metrics in addition to
      existing `inline_code_size` and `outlined_code_size` keys:
      `code_gc_count`, `live_page_count`, `freed_page_count`, and `freed_code_size`.
* Most of the statistics produced by RubyVM::YJIT.runtime_stats are now available in release builds.
    * Simply run ruby with `--yjit-stats` to compute stats (incurs some run-time overhead).
* YJIT is now optimized to take advantage of object shapes. [[Feature #18776]]
* Take advantage of finer-grained constant invalidation to invalidate less code when defining new constants. [[Feature #18589]]

### MJIT

* The MJIT compiler is re-implemented in Ruby as a standard library `mjit`.
* MJIT compiler is executed under a forked Ruby process instead of
  doing it in a native thread called MJIT worker. [[Feature #18968]]
    * As a result, Microsoft Visual Studio (MSWIN) is no longer supported.
* MinGW is no longer supported. [[Feature #18824]]
* Rename `--mjit-min-calls` to `--mjit-call-threshold`.
* Change default `--mjit-max-cache` back from 10000 to 100.

## Static analysis

### RBS

### TypeProf

## Debugger

## error_highlight

## IRB Autocomplete and Document Display

## Miscellaneous changes

[Feature #12005]: https://bugs.ruby-lang.org/issues/12005
[Feature #12084]: https://bugs.ruby-lang.org/issues/12084
[Feature #12655]: https://bugs.ruby-lang.org/issues/12655
[Feature #12737]: https://bugs.ruby-lang.org/issues/12737
[Feature #13110]: https://bugs.ruby-lang.org/issues/13110
[Feature #14332]: https://bugs.ruby-lang.org/issues/14332
[Feature #15231]: https://bugs.ruby-lang.org/issues/15231
[Feature #15357]: https://bugs.ruby-lang.org/issues/15357
[Bug #15928]:     https://bugs.ruby-lang.org/issues/15928
[Feature #16122]: https://bugs.ruby-lang.org/issues/16122
[Feature #16131]: https://bugs.ruby-lang.org/issues/16131
[Bug #16466]:     https://bugs.ruby-lang.org/issues/16466
[Feature #16806]: https://bugs.ruby-lang.org/issues/16806
[Bug #16889]:     https://bugs.ruby-lang.org/issues/16889
[Bug #16908]:     https://bugs.ruby-lang.org/issues/16908
[Feature #16989]: https://bugs.ruby-lang.org/issues/16989
[Feature #17351]: https://bugs.ruby-lang.org/issues/17351
[Feature #17391]: https://bugs.ruby-lang.org/issues/17391
[Bug #17545]:     https://bugs.ruby-lang.org/issues/17545
[Feature #17881]: https://bugs.ruby-lang.org/issues/17881
[Feature #18037]: https://bugs.ruby-lang.org/issues/18037
[Feature #18159]: https://bugs.ruby-lang.org/issues/18159
[Feature #18351]: https://bugs.ruby-lang.org/issues/18351
[Feature #18481]: https://bugs.ruby-lang.org/issues/18481
[Bug #18487]:     https://bugs.ruby-lang.org/issues/18487
[Feature #18571]: https://bugs.ruby-lang.org/issues/18571
[Feature #18585]: https://bugs.ruby-lang.org/issues/18585
[Feature #18589]: https://bugs.ruby-lang.org/issues/18589
[Feature #18598]: https://bugs.ruby-lang.org/issues/18598
[Bug #18625]:     https://bugs.ruby-lang.org/issues/18625
[Feature #18630]: https://bugs.ruby-lang.org/issues/18630
[Bug #18633]:     https://bugs.ruby-lang.org/issues/18633
[Feature #18685]: https://bugs.ruby-lang.org/issues/18685
[Feature #18776]: https://bugs.ruby-lang.org/issues/18776
[Bug #18782]:     https://bugs.ruby-lang.org/issues/18782
[Feature #18788]: https://bugs.ruby-lang.org/issues/18788
[Feature #18809]: https://bugs.ruby-lang.org/issues/18809
[Feature #18821]: https://bugs.ruby-lang.org/issues/18821
[Feature #18824]: https://bugs.ruby-lang.org/issues/18824
[Feature #18925]: https://bugs.ruby-lang.org/issues/18925
[Feature #18949]: https://bugs.ruby-lang.org/issues/18949
[Feature #18968]: https://bugs.ruby-lang.org/issues/18968
[Feature #19008]: https://bugs.ruby-lang.org/issues/19008
[Feature #19013]: https://bugs.ruby-lang.org/issues/19013
[Feature #19026]: https://bugs.ruby-lang.org/issues/19026
[Feature #19060]: https://bugs.ruby-lang.org/issues/19060
[Feature #19070]: https://bugs.ruby-lang.org/issues/19070
[Feature #19071]: https://bugs.ruby-lang.org/issues/19071
[Bug #19100]:     https://bugs.ruby-lang.org/issues/19100
[Feature #19135]: https://bugs.ruby-lang.org/issues/19135
