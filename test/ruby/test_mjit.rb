# frozen_string_literal: true
require 'test/unit'
require 'tmpdir'
require_relative '../lib/jit_support'

# Test for --mjit option
class TestMJIT < Test::Unit::TestCase
  include JITSupport

  IGNORABLE_PATTERNS = [
    /\AJIT recompile: .+\n\z/,
    /\AJIT inline: .+\n\z/,
    /\AJIT cancel: .+\n\z/,
    /\ASuccessful MJIT finish\n\z/,
  ]
  MAX_CACHE_PATTERNS = [
    /\AJIT compaction \([^)]+\): .+\n\z/,
    /\AToo many JIT code, but skipped unloading units for JIT compaction\n\z/,
    /\ANo units can be unloaded -- .+\n\z/,
  ]

  # trace_* insns are not compiled for now...
  TEST_PENDING_INSNS = RubyVM::INSTRUCTION_NAMES.select { |n| n.start_with?('trace_') }.map(&:to_sym) + [
    # not supported yet
    :defineclass,

    # never used
    :opt_invokebuiltin_delegate,
  ].each do |insn|
    if !RubyVM::INSTRUCTION_NAMES.include?(insn.to_s)
      warn "instruction #{insn.inspect} is not defined but included in TestMJIT::TEST_PENDING_INSNS"
    end
  end

  def self.untested_insns
    @untested_insns ||= (RubyVM::INSTRUCTION_NAMES.map(&:to_sym) - TEST_PENDING_INSNS)
  end

  def self.setup
    return if defined?(@setup_hooked)
    @setup_hooked = true

    # ci.rvm.jp caches its build environment. Clean up temporary files left by SEGV.
    if ENV['RUBY_DEBUG']&.include?('ci')
      Dir.glob("#{ENV.fetch('TMPDIR', '/tmp')}/_ruby_mjit_p*u*.*").each do |file|
        puts "test/ruby/test_mjit.rb: removing #{file}"
        File.unlink(file)
      end
    end

    # ruby -w -Itest/lib test/ruby/test_mjit.rb
    if $VERBOSE
      pid = $$
      at_exit do
        if pid == $$ && !TestMJIT.untested_insns.empty?
          warn "you may want to add tests for following insns, when you have a chance: #{TestMJIT.untested_insns.join(' ')}"
        end
      end
    end
  end

  def setup
    unless JITSupport.supported?
      omit 'JIT seems not supported on this platform'
    end
    self.class.setup
  end

  def test_compile_insn_nop
    assert_compile_once('nil rescue true', result_inspect: 'nil', insns: %i[nop])
  end

  def test_compile_insn_local
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '1', insns: %i[setlocal_WC_0 getlocal_WC_0])
    begin;
      foo = 1
      foo
    end;

    insns = %i[setlocal getlocal setlocal_WC_0 getlocal_WC_0 setlocal_WC_1 getlocal_WC_1]
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", success_count: 3, stdout: '168', insns: insns)
    begin;
      def foo
        a = 0
        [1, 2].each do |i|
          a += i
          [3, 4].each do |j|
            a *= j
          end
        end
        a
      end

      print foo
    end;
  end

  def test_compile_insn_blockparam
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '3', success_count: 2, insns: %i[getblockparam setblockparam])
    begin;
      def foo(&b)
        a = b
        b = 2
        a.call + 2
      end

      print foo { 1 }
    end;
  end

  def test_compile_insn_getblockparamproxy
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '4', success_count: 3, insns: %i[getblockparamproxy])
    begin;
      def bar(&b)
        b.call
      end

      def foo(&b)
        bar(&b) * bar(&b)
      end

      print foo { 2 }
    end;
  end

  def test_compile_insn_getspecial
    assert_compile_once('$1', result_inspect: 'nil', insns: %i[getspecial])
  end

  def test_compile_insn_setspecial
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: 'true', insns: %i[setspecial])
    begin;
      true if nil.nil?..nil.nil?
    end;
  end

  def test_compile_insn_instancevariable
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '1', insns: %i[getinstancevariable setinstancevariable])
    begin;
      @foo = 1
      @foo
    end;

    # optimized getinstancevariable call
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '33', success_count: 1, call_threshold: 2)
    begin;
      class A
        def initialize
          @a = 1
          @b = 2
        end

        def three
          @a + @b
        end
      end

      a = A.new
      print(a.three) # set ic
      print(a.three) # inlined ic
    end;
  end

  def test_compile_insn_classvariable
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '1', success_count: 1, insns: %i[getclassvariable setclassvariable])
    begin;
      class Foo
        def self.foo
          @@foo = 1
          @@foo
        end
      end

      print Foo.foo
    end;
  end

  def test_compile_insn_constant
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '1', insns: %i[opt_getconstant_path setconstant])
    begin;
      FOO = 1
      FOO
    end;
  end

  def test_compile_insn_global
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '1', insns: %i[getglobal setglobal])
    begin;
      $foo = 1
      $foo
    end;
  end

  def test_compile_insn_putnil
    assert_compile_once('nil', result_inspect: 'nil', insns: %i[putnil])
  end

  def test_compile_insn_putself
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'hello', success_count: 1, insns: %i[putself])
    begin;
      proc { print "hello" }.call
    end;
  end

  def test_compile_insn_putobject
    assert_compile_once('0', result_inspect: '0', insns: %i[putobject_INT2FIX_0_])
    assert_compile_once('1', result_inspect: '1', insns: %i[putobject_INT2FIX_1_])
    assert_compile_once('2', result_inspect: '2', insns: %i[putobject])
  end

  def test_compile_insn_definemethod_definesmethod
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'helloworld', success_count: 3, insns: %i[definemethod definesmethod])
    begin;
      print 1.times.map {
        def method_definition
          'hello'
        end

        def self.smethod_definition
          'world'
        end

        method_definition + smethod_definition
      }.join
    end;
  end

  def test_compile_insn_putspecialobject
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'a', success_count: 2, insns: %i[putspecialobject])
    begin;
      print 1.times.map {
        def a
          'a'
        end

        alias :b :a

        b
      }.join
    end;
  end

  def test_compile_insn_putstring_concatstrings_objtostring
    assert_compile_once('"a#{}b" + "c"', result_inspect: '"abc"', insns: %i[putstring concatstrings objtostring])
  end

  def test_compile_insn_toregexp
    assert_compile_once('/#{true}/ =~ "true"', result_inspect: '0', insns: %i[toregexp])
  end

  def test_compile_insn_newarray
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '[1, 2, 3]', insns: %i[newarray])
    begin;
      a, b, c = 1, 2, 3
      [a, b, c]
    end;
  end

  def test_compile_insn_newarraykwsplat
    assert_compile_once('[**{ x: 1 }]', result_inspect: '[{:x=>1}]', insns: %i[newarraykwsplat])
  end

  def test_compile_insn_intern_duparray
    assert_compile_once('[:"#{0}"] + [1,2,3]', result_inspect: '[:"0", 1, 2, 3]', insns: %i[intern duparray])
  end

  def test_compile_insn_expandarray
    assert_compile_once('y = [ true, false, nil ]; x, = y; x', result_inspect: 'true', insns: %i[expandarray])
  end

  def test_compile_insn_concatarray
    assert_compile_once('["t", "r", *x = "u", "e"].join', result_inspect: '"true"', insns: %i[concatarray])
  end

  def test_compile_insn_splatarray
    assert_compile_once('[*(1..2)]', result_inspect: '[1, 2]', insns: %i[splatarray])
  end

  def test_compile_insn_newhash
    assert_compile_once('a = 1; { a: a }', result_inspect: '{:a=>1}', insns: %i[newhash])
  end

  def test_compile_insn_duphash
    assert_compile_once('{ a: 1 }', result_inspect: '{:a=>1}', insns: %i[duphash])
  end

  def test_compile_insn_newrange
    assert_compile_once('a = 1; 0..a', result_inspect: '0..1', insns: %i[newrange])
  end

  def test_compile_insn_pop
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '1', insns: %i[pop])
    begin;
      a = false
      b = 1
      a || b
    end;
  end

  def test_compile_insn_dup
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '3', insns: %i[dup])
    begin;
      a = 1
      a&.+(2)
    end;
  end

  def test_compile_insn_dupn
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: 'true', insns: %i[dupn])
    begin;
      klass = Class.new
      klass::X ||= true
    end;
  end

  def test_compile_insn_swap_topn
    assert_compile_once('{}["true"] = true', result_inspect: 'true', insns: %i[swap topn])
  end

  def test_compile_insn_reput
    omit "write test"
  end

  def test_compile_insn_setn
    assert_compile_once('[nil][0] = 1', result_inspect: '1', insns: %i[setn])
  end

  def test_compile_insn_adjuststack
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: 'true', insns: %i[adjuststack])
    begin;
      x = [true]
      x[0] ||= nil
      x[0]
    end;
  end

  def test_compile_insn_defined
    assert_compile_once('defined?(a)', result_inspect: 'nil', insns: %i[defined])
  end

  def test_compile_insn_checkkeyword
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'true', success_count: 1, insns: %i[checkkeyword])
    begin;
      def test(x: rand)
        x
      end
      print test(x: true)
    end;
  end

  def test_compile_insn_tracecoverage
    omit "write test"
  end

  def test_compile_insn_defineclass
    omit "support this in mjit_compile (low priority)"
  end

  def test_compile_insn_send
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '1', success_count: 3, insns: %i[send])
    begin;
      print proc { yield_self { 1 } }.call
    end;
  end

  def test_compile_insn_opt_str_freeze
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '"foo"', insns: %i[opt_str_freeze])
    begin;
      'foo'.freeze
    end;
  end

  def test_compile_insn_opt_nil_p
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: 'false', insns: %i[opt_nil_p])
    begin;
      nil.nil?.nil?
    end;
  end

  def test_compile_insn_opt_str_uminus
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '"bar"', insns: %i[opt_str_uminus])
    begin;
      -'bar'
    end;
  end

  def test_compile_insn_opt_newarray_max
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '2', insns: %i[opt_newarray_max])
    begin;
      a = 1
      b = 2
      [a, b].max
    end;
  end

  def test_compile_insn_opt_newarray_min
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '1', insns: %i[opt_newarray_min])
    begin;
      a = 1
      b = 2
      [a, b].min
    end;
  end

  def test_compile_insn_opt_send_without_block
    assert_compile_once('print', result_inspect: 'nil', insns: %i[opt_send_without_block])
  end

  def test_compile_insn_invokesuper
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '3', success_count: 4, insns: %i[invokesuper])
    begin;
      mod = Module.new {
        def test
          super + 2
        end
      }
      klass = Class.new {
        prepend mod
        def test
          1
        end
      }
      print klass.new.test
    end;
  end

  def test_compile_insn_invokeblock_leave
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '2', success_count: 2, insns: %i[invokeblock leave])
    begin;
      def foo
        yield
      end
      print foo { 2 }
    end;
  end

  def test_compile_insn_throw
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '4', success_count: 2, insns: %i[throw])
    begin;
      def test
        proc do
          if 1+1 == 1
            return 3
          else
            return 4
          end
          5
        end.call
      end
      print test
    end;
  end

  def test_compile_insn_jump_branchif
    assert_compile_once("#{<<~"begin;"}\n#{<<~'end;'}", result_inspect: 'nil', insns: %i[jump branchif])
    begin;
      a = false
      1 + 1 while a
    end;
  end

  def test_compile_insn_branchunless
    assert_compile_once("#{<<~"begin;"}\n#{<<~'end;'}", result_inspect: '1', insns: %i[branchunless])
    begin;
      a = true
      if a
        1
      else
        2
      end
    end;
  end

  def test_compile_insn_branchnil
    assert_compile_once("#{<<~"begin;"}\n#{<<~'end;'}", result_inspect: '3', insns: %i[branchnil])
    begin;
      a = 2
      a&.+(1)
    end;
  end

  def test_compile_insn_objtostring
    assert_compile_once("#{<<~"begin;"}\n#{<<~'end;'}", result_inspect: '"42"', insns: %i[objtostring])
    begin;
      a = '2'
      "4#{a}"
    end;
  end

  def test_compile_insn_getconstant_path
    assert_compile_once('Struct', result_inspect: 'Struct', insns: %i[opt_getconstant_path])
  end

  def test_compile_insn_once
    assert_compile_once('/#{true}/o =~ "true" && $~.to_a', result_inspect: '["true"]', insns: %i[once])
  end

  def test_compile_insn_checkmatch_opt_case_dispatch
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '"world"', insns: %i[opt_case_dispatch])
    begin;
      case 'hello'
      when 'hello'
        'world'
      end
    end;
  end

  def test_compile_insn_opt_calc
    assert_compile_once('4 + 2 - ((2 * 3 / 2) % 2)', result_inspect: '5', insns: %i[opt_plus opt_minus opt_mult opt_div opt_mod])
    assert_compile_once('4.0 + 2.0 - ((2.0 * 3.0 / 2.0) % 2.0)', result_inspect: '5.0', insns: %i[opt_plus opt_minus opt_mult opt_div opt_mod])
    assert_compile_once('4 + 2', result_inspect: '6')
  end

  def test_compile_insn_opt_cmp
    assert_compile_once('(1 == 1) && (1 != 2)', result_inspect: 'true', insns: %i[opt_eq opt_neq])
  end

  def test_compile_insn_opt_rel
    assert_compile_once('1 < 2 && 1 <= 1 && 2 > 1 && 1 >= 1', result_inspect: 'true', insns: %i[opt_lt opt_le opt_gt opt_ge])
  end

  def test_compile_insn_opt_ltlt
    assert_compile_once('[1] << 2', result_inspect: '[1, 2]', insns: %i[opt_ltlt])
  end

  def test_compile_insn_opt_and
    assert_compile_once('1 & 3', result_inspect: '1', insns: %i[opt_and])
  end

  def test_compile_insn_opt_or
    assert_compile_once('1 | 3', result_inspect: '3', insns: %i[opt_or])
  end

  def test_compile_insn_opt_aref
    # optimized call (optimized JIT) -> send call
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '21', success_count: 2, call_threshold: 1, insns: %i[opt_aref])
    begin;
      obj = Object.new
      def obj.[](h)
        h
      end

      block = proc { |h| h[1] }
      print block.call({ 1 => 2 })
      print block.call(obj)
    end;

    # send call -> optimized call (send JIT) -> optimized call
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '122', success_count: 2, call_threshold: 2)
    begin;
      obj = Object.new
      def obj.[](h)
        h
      end

      block = proc { |h| h[1] }
      print block.call(obj)
      print block.call({ 1 => 2 })
      print block.call({ 1 => 2 })
    end;
  end

  def test_compile_insn_opt_aref_with
    assert_compile_once("{ '1' => 2 }['1']", result_inspect: '2', insns: %i[opt_aref_with])
  end

  def test_compile_insn_opt_aset
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '5', insns: %i[opt_aset opt_aset_with])
    begin;
      hash = { '1' => 2 }
      (hash['2'] = 2) + (hash[1.to_s] = 3)
    end;
  end

  def test_compile_insn_opt_length_size
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '4', insns: %i[opt_length opt_size])
    begin;
      array = [1, 2]
      array.length + array.size
    end;
  end

  def test_compile_insn_opt_empty_p
    assert_compile_once('[].empty?', result_inspect: 'true', insns: %i[opt_empty_p])
  end

  def test_compile_insn_opt_succ
    assert_compile_once('1.succ', result_inspect: '2', insns: %i[opt_succ])
  end

  def test_compile_insn_opt_not
    assert_compile_once('!!true', result_inspect: 'true', insns: %i[opt_not])
  end

  def test_compile_insn_opt_regexpmatch2
    assert_compile_once("/true/ =~ 'true'", result_inspect: '0', insns: %i[opt_regexpmatch2])
    assert_compile_once("'true' =~ /true/", result_inspect: '0', insns: %i[opt_regexpmatch2])
  end

  def test_compile_insn_invokebuiltin
    iseq = eval(EnvUtil.invoke_ruby(['-e', <<~'EOS'], '', true).first)
      p RubyVM::InstructionSequence.of([].method(:sample)).to_a
    EOS
    insns = collect_insns(iseq)
    mark_tested_insn(:invokebuiltin, used_insns: insns)
    assert_eval_with_jit('print [].sample(1)', stdout: '[]', success_count: 1)
  end

  def test_compile_insn_opt_invokebuiltin_delegate_leave
    iseq = eval(EnvUtil.invoke_ruby(['-e', <<~'EOS'], '', true).first)
      p RubyVM::InstructionSequence.of("\x00".method(:unpack)).to_a
    EOS
    insns = collect_insns(iseq)
    mark_tested_insn(:opt_invokebuiltin_delegate_leave, used_insns: insns)
    assert_eval_with_jit('print "\x00".unpack("c")', stdout: '[0]', success_count: 1)
  end

  def test_compile_insn_checkmatch
    assert_compile_once("#{<<~"begin;"}\n#{<<~"end;"}", result_inspect: '"world"', insns: %i[checkmatch])
    begin;
      ary = %w(hello good-bye)
      case 'hello'
      when *ary
        'world'
      end
    end;
  end

  def test_compile_opt_pc
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'hello', success_count: 1)
    begin;
      def test(arg = 'hello')
        print arg
      end
      test
    end;
  end

  def test_mjit_output
    out, err = eval_with_jit('5.times { puts "MJIT" }', verbose: 1, call_threshold: 5)
    assert_equal("MJIT\n" * 5, out)
    assert_match(/^#{JIT_SUCCESS_PREFIX}: block in <main>@-e:1 -> .+_ruby_mjit_p\d+u\d+\.c$/, err)
    assert_match(/^Successful MJIT finish$/, err)
  end

  def test_nothing_to_unload_with_jit_wait
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'hello', success_count: 11, max_cache: 10, ignorable_patterns: MAX_CACHE_PATTERNS)
    begin;
      def a1() a2() end
      def a2() a3() end
      def a3() a4() end
      def a4() a5() end
      def a5() a6() end
      def a6() a7() end
      def a7() a8() end
      def a8() a9() end
      def a9() a10() end
      def a10() a11() end
      def a11() print('hello') end
      a1
    end;
  end

  def test_unload_units_on_fiber
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: 'hello', success_count: 12, max_cache: 10, ignorable_patterns: MAX_CACHE_PATTERNS)
    begin;
      def a1() a2(false); a2(true) end
      def a2(a) a3(a) end
      def a3(a) a4(a) end
      def a4(a) a5(a) end
      def a5(a) a6(a) end
      def a6(a) a7(a) end
      def a7(a) a8(a) end
      def a8(a) a9(a) end
      def a9(a) a10(a) end
      def a10(a)
        if a
          Fiber.new { a11 }.resume
        end
      end
      def a11() print('hello') end
      a1
    end;
  end

  def test_unload_units_and_compaction
    Dir.mktmpdir("jit_test_unload_units_") do |dir|
      # MIN_CACHE_SIZE is 10
      out, err = eval_with_jit({"TMPDIR"=>dir}, "#{<<~"begin;"}\n#{<<~'end;'}", verbose: 1, call_threshold: 1, max_cache: 10)
      begin;
        i = 0
        while i < 11
          eval(<<-EOS)
            def mjit#{i}
              print #{i}
            end
            mjit#{i}
          EOS
          i += 1
        end

        if defined?(fork)
          # test the child does not try to delete files which are deleted by parent,
          # and test possible deadlock on fork during MJIT unload and JIT compaction on child
          Process.waitpid(Process.fork {})
        end
      end;

      debug_info = %Q[stdout:\n"""\n#{out}\n"""\n\nstderr:\n"""\n#{err}"""\n]
      assert_equal('012345678910', out, debug_info)
      compactions, errs = err.lines.partition do |l|
        l.match?(/\AJIT compaction \(\d+\.\dms\): Compacted \d+ methods /)
      end
      10.times do |i|
        assert_match(/\A#{JIT_SUCCESS_PREFIX}: mjit#{i}@\(eval\):/, errs[i], debug_info)
      end

      assert_equal("No units can be unloaded -- incremented max-cache-size to 11 for --jit-wait\n", errs[10], debug_info)
      assert_match(/\A#{JIT_SUCCESS_PREFIX}: mjit10@\(eval\):/, errs[11], debug_info)
      # On --jit-wait, when the number of JIT-ed code reaches --jit-max-cache,
      # it should trigger compaction.
      unless RUBY_PLATFORM.match?(/mswin|mingw/) # compaction is not supported on Windows yet
        assert_equal(1, compactions.size, debug_info)
      end

      if RUBY_PLATFORM.match?(/mswin/)
        # "Permission Denied" error is preventing to remove so file on AppVeyor/RubyCI.
        omit 'Removing so file is randomly failing on AppVeyor/RubyCI mswin due to Permission Denied.'
      end
      if RUBY_PLATFORM.match?(/darwin/)
        omit '.bundle.dSYM directory is left but removing it is not supported for now'
      end
      # verify .c files are deleted on unload_units
      assert_send([Dir, :empty?, dir], debug_info)
    end
  end

  def test_newarraykwsplat_on_stack
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "[nil, [{:type=>:development}]]\n", success_count: 1, insns: %i[newarraykwsplat])
    begin;
      def arr
        [nil, [:type => :development]]
      end
      p arr
    end;
  end

  def test_local_stack_on_exception
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '3', success_count: 2)
    begin;
      def b
        raise
      rescue
        2
      end

      def a
        # Calling #b should be vm_exec, not direct jit_exec.
        # Otherwise `1` on local variable would be purged.
        1 + b
      end

      print a
    end;
  end

  def test_local_stack_with_sp_motion_by_blockargs
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '1', success_count: 2)
    begin;
      def b(base)
        1
      end

      # This method is simple enough to have false in catch_except_p.
      # So local_stack_p would be true in JIT compiler.
      def a
        m = method(:b)

        # ci->flag has VM_CALL_ARGS_BLOCKARG and cfp->sp is moved in vm_caller_setup_arg_block.
        # So, for this send insn, JIT-ed code should use cfp->sp instead of local variables for stack.
        Module.module_eval(&m)
      end

      print a
    end;
  end

  def test_catching_deep_exception
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '1', success_count: 4)
    begin;
      def catch_true(paths, prefixes) # catch_except_p: true
        prefixes.each do |prefix| # catch_except_p: true
          paths.each do |path| # catch_except_p: false
            return path
          end
        end
      end

      def wrapper(paths, prefixes)
        catch_true(paths, prefixes)
      end

      print wrapper(['1'], ['2'])
    end;
  end

  def test_inlined_builtin_methods
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '', success_count: 1, call_threshold: 2)
    begin;
      def test
        float = 0.0
        float.abs
        float.-@
        float.zero?
      end
      test
      test
    end;
  end

  def test_inlined_c_method
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "aaa", success_count: 2, recompile_count: 1, call_threshold: 2)
    begin;
      def test(obj, recursive: nil)
        if recursive
          test(recursive)
        end
        obj.to_s
      end

      print(test('a')) # set #to_s cc to String#to_s (expecting C method)
      print(test('a')) # JIT with #to_s cc: String#to_s
      # update #to_s cd->cc to Symbol#to_s, then go through the Symbol#to_s cd->cc
      # after checking receiver class using inlined #to_s cc with String#to_s.
      print(test('a', recursive: :foo))
    end;
  end

  def test_inlined_exivar
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "aaa", success_count: 4, recompile_count: 2, call_threshold: 2)
    begin;
      class Foo < Hash
        def initialize
          @a = :a
        end

        def bar
          @a
        end
      end

      print(Foo.new.bar)
      print(Foo.new.bar) # compile #initialize, #bar -> recompile #bar
      print(Foo.new.bar) # compile #bar with exivar
    end;
  end

  def test_inlined_undefined_ivar
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "bbb", success_count: 5, call_threshold: 2)
    begin;
      class Foo
        def initialize
          @a = :a
        end

        def bar
          if @b.nil?
            @b = :b
          end
        end
      end

      print(Foo.new.bar)
      print(Foo.new.bar)
      print(Foo.new.bar)
    end;
  end

  def test_inlined_setivar_frozen
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "FrozenError\n", success_count: 2, call_threshold: 3)
    begin;
      class A
        def a
          @a = 1
        end
      end

      a = A.new
      a.a
      a.a
      a.a
      a.freeze
      begin
        a.a
      rescue FrozenError => e
        p e.class
      end
    end;
  end

  def test_inlined_getconstant
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '11', success_count: 1, call_threshold: 2)
    begin;
      FOO = 1
      def const
        FOO
      end
      print const
      print const
    end;
  end

  def test_attr_reader
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "4nil\nnil\n6", success_count: 2, call_threshold: 2)
    begin;
      class A
        attr_reader :a, :b

        def initialize
          @a = 2
        end

        def test
          a
        end

        def undefined
          b
        end
      end

      a = A.new
      print(a.test * a.test)
      p(a.undefined)
      p(a.undefined)

      # redefinition
      def a.test
        3
      end

      print(2 * a.test)
    end;

    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "true", success_count: 1, call_threshold: 2)
    begin;
      class Hoge
        attr_reader :foo

        def initialize
          @foo = []
          @bar = nil
        end
      end

      class Fuga < Hoge
        def initialize
          @bar = nil
          @foo = []
        end
      end

      def test(recv)
        recv.foo.empty?
      end

      hoge = Hoge.new
      fuga = Fuga.new

      test(hoge) # VM: cc set index=1
      test(hoge) # JIT: compile with index=1
      test(fuga) # JIT -> VM: cc set index=2
      print test(hoge) # JIT: should use index=1, not index=2 in cc
    end;
  end

  def test_heap_promotion_of_ivar_in_the_middle_of_jit
    omit if GC.using_rvargc?

    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "true\ntrue\n", success_count: 2, call_threshold: 2)
    begin;
      class A
        def initialize
          @iv0 = nil
          @iv1 = []
        end

        def test(add)
          @iv0.nil?
          add_ivar if add
          @iv1.empty?
        end

        def add_ivar
          @iv2 = nil
          @iv3 = nil
        end
      end

      a = A.new
      p a.test(false)
      p a.test(true)
    end;
  end

  def test_jump_to_precompiled_branch
    assert_eval_with_jit("#{<<~'begin;'}\n#{<<~'end;'}", stdout: ".0", success_count: 1, call_threshold: 1)
    begin;
      def test(foo)
        ".#{foo unless foo == 1}" if true
      end
      print test(0)
    end;
  end

  def test_clean_so
    if RUBY_PLATFORM.match?(/mswin/)
      omit 'Removing so file is randomly failing on AppVeyor/RubyCI mswin due to Permission Denied.'
    end
    if RUBY_PLATFORM.match?(/darwin/)
      omit '.bundle.dSYM directory is left but removing it is not supported for now'
    end
    Dir.mktmpdir("jit_test_clean_so_") do |dir|
      code = "x = 0; 10.times {|i|x+=i}"
      eval_with_jit({"TMPDIR"=>dir}, code)
      assert_send([Dir, :empty?, dir], "Directory #{dir} was not empty:\n#{Dir.glob("#{dir}/*").join("\n")}\n")
      eval_with_jit({"TMPDIR"=>dir}, code, save_temps: true)
      assert_not_send([Dir, :empty?, dir])
    end
  end

  def test_clean_objects_on_exec
    if /mswin|mingw/ =~ RUBY_PLATFORM
      # TODO: check call stack and close handle of code which is not on stack, and remove objects on best-effort basis
      omit 'Removing so file being used does not work on Windows'
    end
    if RUBY_PLATFORM.match?(/darwin/)
      omit '.bundle.dSYM directory is left but removing it is not supported for now'
    end
    Dir.mktmpdir("jit_test_clean_objects_on_exec_") do |dir|
      eval_with_jit({"TMPDIR"=>dir}, "#{<<~"begin;"}\n#{<<~"end;"}", call_threshold: 1)
      begin;
        def a; end; a
        exec "true"
      end;
      error_message = "Undeleted files:\n  #{Dir.glob("#{dir}/*").join("\n  ")}\n"
      assert_send([Dir, :empty?, dir], error_message)
    end
  end

  def test_lambda_longjmp
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '5', success_count: 1)
    begin;
      fib = lambda do |x|
        return x if x == 0 || x == 1
        fib.call(x-1) + fib.call(x-2)
      end
      print fib.call(5)
    end;
  end

  def test_stack_pointer_with_assignment
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "nil\nnil\n", success_count: 1)
    begin;
      2.times do
        a, _ = nil
        p a
      end
    end;
  end

  def test_frame_omitted_inlining
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "true\ntrue\ntrue\n", success_count: 1, call_threshold: 2)
    begin;
      class Integer
        remove_method :zero?
        def zero?
          self == 0
        end
      end

      3.times do
        p 0.zero?
      end
    end;
  end

  def test_block_handler_with_possible_frame_omitted_inlining
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "70.0\n70.0\n70.0\n", success_count: 2, call_threshold: 2)
    begin;
      def multiply(a, b)
        a *= b
      end

      3.times do
        p multiply(7.0, 10.0)
      end
    end;
  end

  def test_builtin_frame_omitted_inlining
    assert_eval_with_jit('0.zero?; 0.zero?; 3.times { p 0.zero? }', stdout: "true\ntrue\ntrue\n", success_count: 1, call_threshold: 2)
  end

  def test_program_counter_with_regexpmatch
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "aa", success_count: 1)
    begin;
      2.times do
        break if /a/ =~ "ab" && !$~[0]
        print $~[0]
      end
    end;
  end

  def test_pushed_values_with_opt_aset_with
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "{}{}", success_count: 1)
    begin;
      2.times do
        print(Thread.current["a"] = {})
      end
    end;
  end

  def test_pushed_values_with_opt_aref_with
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: "nil\nnil\n", success_count: 1)
    begin;
      2.times do
        p(Thread.current["a"])
      end
    end;
  end

  def test_mjit_pause_wait
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", stdout: '', success_count: 0, call_threshold: 1)
    begin;
      RubyVM::MJIT.pause
      proc {}.call
    end;
  end

  def test_not_cancel_by_tracepoint_class
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", success_count: 1, call_threshold: 2)
    begin;
      TracePoint.new(:class) {}.enable
      2.times {}
    end;
  end

  def test_cancel_by_tracepoint
    assert_eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", success_count: 0, call_threshold: 2)
    begin;
      TracePoint.new(:line) {}.enable
      2.times {}
    end;
  end

  def test_caller_locations_without_catch_table
    out, _ = eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", call_threshold: 1)
    begin;
      def b                             # 2
        caller_locations.first          # 3
      end                               # 4
                                        # 5
      def a                             # 6
        print # <-- don't leave PC here # 7
        b                               # 8
      end
      puts a
      puts a
    end;
    lines = out.lines
    assert_equal("-e:8:in `a'\n", lines[0])
    assert_equal("-e:8:in `a'\n", lines[1])
  end

  def test_fork_with_mjit_worker_thread
    Dir.mktmpdir("jit_test_fork_with_mjit_worker_thread_") do |dir|
      # call_threshold: 2 to skip fork block
      out, err = eval_with_jit({ "TMPDIR" => dir }, "#{<<~"begin;"}\n#{<<~"end;"}", call_threshold: 2, verbose: 1)
      begin;
        def before_fork; end
        def after_fork; end

        before_fork; before_fork # the child should not delete this .o file
        pid = Process.fork do # this child should not delete shared .pch file
          sleep 2.0 # to prevent mixing outputs on Solaris
          after_fork; after_fork # this child does not share JIT-ed after_fork with parent
        end
        after_fork; after_fork # this parent does not share JIT-ed after_fork with child

        Process.waitpid(pid)
      end;
      success_count = err.scan(/^#{JIT_SUCCESS_PREFIX}:/).size
      debug_info = "stdout:\n```\n#{out}\n```\n\nstderr:\n```\n#{err}```\n"
      assert_equal(3, success_count, debug_info)

      # assert no remove error
      assert_equal("Successful MJIT finish\n" * 2, err.gsub(/^#{JIT_SUCCESS_PREFIX}:[^\n]+\n/, ''), debug_info)

      # ensure objects are deleted
      if RUBY_PLATFORM.match?(/darwin/)
        omit '.bundle.dSYM directory is left but removing it is not supported for now'
      end
      assert_send([Dir, :empty?, dir], debug_info)
    end
  end if defined?(fork)

  def test_jit_failure
    _, err = eval_with_jit("#{<<~"begin;"}\n#{<<~"end;"}", call_threshold: 1, verbose: 1)
    begin;
      1.times do
        class A
        end
      end
    end;
    assert_match(/^MJIT warning: .+ unsupported instruction: defineclass/, err)
    assert_match(/^JIT failure: block in <main>/, err)
  end

  private

  # The shortest way to test one proc
  def assert_compile_once(script, result_inspect:, insns: [], uplevel: 1)
    if script.match?(/\A\n.+\n\z/m)
      script = script.gsub(/^/, '  ')
    else
      script = " #{script} "
    end
    assert_eval_with_jit("p proc {#{script}}.call", stdout: "#{result_inspect}\n", success_count: 1, insns: insns, uplevel: uplevel + 1)
  end

  # Shorthand for normal test cases
  def assert_eval_with_jit(script, stdout: nil, success_count:, recompile_count: nil, call_threshold: 1, max_cache: 1000, insns: [], uplevel: 1, ignorable_patterns: [])
    out, err = eval_with_jit(script, verbose: 1, call_threshold: call_threshold, max_cache: max_cache)
    success_actual = err.scan(/^#{JIT_SUCCESS_PREFIX}:/).size
    recompile_actual = err.scan(/^#{JIT_RECOMPILE_PREFIX}:/).size
    # Add --mjit-verbose=2 logs for cl.exe because compiler's error message is suppressed
    # for cl.exe with --mjit-verbose=1. See `start_process` in mjit.c.
    if RUBY_PLATFORM.match?(/mswin/) && success_count != success_actual
      out2, err2 = eval_with_jit(script, verbose: 2, call_threshold: call_threshold, max_cache: max_cache)
    end

    # Make sure that the script has insns expected to be tested
    used_insns = method_insns(script)
    insns.each do |insn|
      mark_tested_insn(insn, used_insns: used_insns, uplevel: uplevel + 3)
    end

    suffix = "script:\n#{code_block(script)}\nstderr:\n#{code_block(err)}#{(
      "\nstdout(verbose=2 retry):\n#{code_block(out2)}\nstderr(verbose=2 retry):\n#{code_block(err2)}" if out2 || err2
    )}"
    assert_equal(
      success_count, success_actual,
      "Expected #{success_count} times of JIT success, but succeeded #{success_actual} times.\n\n#{suffix}",
    )
    if recompile_count
      assert_equal(
        recompile_count, recompile_actual,
        "Expected #{success_count} times of JIT recompile, but recompiled #{success_actual} times.\n\n#{suffix}",
      )
    end
    if stdout
      assert_equal(stdout, out, "Expected stdout #{out.inspect} to match #{stdout.inspect} with script:\n#{code_block(script)}")
    end
    err_lines = err.lines.reject! do |l|
      l.chomp.empty? || l.match?(/\A#{JIT_SUCCESS_PREFIX}/) || (IGNORABLE_PATTERNS + ignorable_patterns).any? { |pat| pat.match?(l) }
    end
    unless err_lines.empty?
      warn err_lines.join(''), uplevel: uplevel
    end
  end

  def mark_tested_insn(insn, used_insns:, uplevel: 1)
    # Currently, this check emits a false-positive warning against opt_regexpmatch2,
    # so the insn is excluded explicitly. See https://bugs.ruby-lang.org/issues/18269
    if !used_insns.include?(insn) && insn != :opt_regexpmatch2
      $stderr.puts
      warn "'#{insn}' insn is not included in the script. Actual insns are: #{used_insns.join(' ')}\n", uplevel: uplevel
    end
    TestMJIT.untested_insns.delete(insn)
  end

  # Collect block's insns or defined method's insns, which are expected to be JIT-ed.
  # Note that this intentionally excludes insns in script's toplevel because they are not JIT-ed.
  def method_insns(script)
    insns = []
    RubyVM::InstructionSequence.compile(script).to_a.last.each do |(insn, *args)|
      case insn
      when :send
        insns += collect_insns(args.last)
      when :definemethod, :definesmethod
        insns += collect_insns(args[1])
      when :defineclass
        insns += collect_insns(args[1])
      end
    end
    insns.uniq
  end

  # Recursively collect insns in iseq_array
  def collect_insns(iseq_array)
    return [] if iseq_array.nil?

    insns = iseq_array.last.select { |x| x.is_a?(Array) }.map(&:first)
    iseq_array.last.each do |(insn, *args)|
      case insn
      when :definemethod, :definesmethod, :send
        insns += collect_insns(args.last)
      end
    end
    insns
  end
end
