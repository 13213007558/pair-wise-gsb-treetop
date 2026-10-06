require 'spec_helper'
require 'tmpdir'

module BytecodeLoaderSpec
  describe Treetop::Runtime::BytecodeLoader do
    CREATED_CONSTANTS = %i[LoaderTest LoaderTestParser MemoTest MemoTestParser LoaderOuter]

    after(:all) do
      CREATED_CONSTANTS.each do |const|
        Object.send(:remove_const, const) if Object.const_defined?(const, false)
      end
    end

    GRAMMAR_SOURCE = <<~TREETOP
      grammar LoaderTest
        rule top
          first:word ', ' second:word
        end
        rule word
          [a-z]+
        end
      end
    TREETOP

    def compile(source = GRAMMAR_SOURCE)
      Treetop::Compiler::BytecodeCompiler.new.compile_to_artifact(source)
    end

    def load(source = GRAMMAR_SOURCE)
      Treetop::Runtime::BytecodeLoader.load_artifact(compile(source))
    end

    it "loads an artifact into a working parser class" do
      parser_class = load
      result = parser_class.new.parse('one, two')
      result.should_not be_nil
      result.interval.should == (0...8)
      LoaderTestParser.should equal(parser_class)
      LoaderTest::Parser.should equal(parser_class)
    end

    it "round-trips an artifact through a .ttc file without evaluating Ruby" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'loader_test.ttc')
        File.open(path, 'wb') { |file| file.write(Marshal.dump(compile)) }
        parser_class = Treetop.load_bytecode(path)
        parser_class.new.parse('one, two').should_not be_nil
      end
    end

    it "compiles a grammar file to a .ttc artifact" do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'peg_features.ttc')
        Treetop::Compiler::BytecodeCompiler.new.compile(
          File.expand_path('../compiler/bytecode/peg_features.treetop', __dir__), target)
        Treetop.load_bytecode(target).new.parse('aabb', :root => :repeated).should_not be_nil
      end
    end

    it "defines label accessors on sequence nodes without eval" do
      result = load.new.parse('one, two')
      result.first.text_value.should == 'one'
      result.second.text_value.should == 'two'
    end

    it "memoizes rule invocations per index" do
      parser_class = load(<<~TREETOP)
        grammar MemoTest
          rule top
            (word '!' / word '?')
          end
          rule word
            [a-z]+
          end
        end
      TREETOP
      parser = parser_class.new
      result = parser.parse('abc?')
      result.should_not be_nil
      cache = parser.send(:node_cache)
      cache[:word][0].should be(result.elements[0])
    end

    it "rejects artifacts with an unsupported version" do
      artifact = compile
      artifact['version'] += 1
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      }.should raise_error(Treetop::Runtime::BytecodeLoadError, /version/)
    end

    it "rejects data that is not an artifact" do
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact('nonsense')
      }.should raise_error(Treetop::Runtime::BytecodeLoadError)
    end

    it "rejects artifacts with jump targets out of range" do
      artifact = compile
      rule = artifact['rules'].find { |r| r['name'] == 'top' }
      jump = rule['code'].find { |instruction| instruction[0] == :jump_unless }
      jump[1] = 9999
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      }.should raise_error(Treetop::Runtime::BytecodeLoadError, /jump target/)
    end

    it "rejects artifacts with unknown opcodes" do
      artifact = compile
      artifact['rules'].first['code'] << [:frobnicate]
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      }.should raise_error(Treetop::Runtime::BytecodeLoadError, /unknown opcode/)
    end

    it "rejects artifacts calling undefined rules" do
      artifact = compile(<<~TREETOP)
        grammar BadCall
          rule top
            word 'x' / word 'y'
          end
          rule word
            [a-z]+
          end
        end
      TREETOP
      rule = artifact['rules'].find { |r| r['name'] == 'top' }
      call = rule['code'].find { |instruction| instruction[0] == :call }
      call[1] = 'nonexistent_rule'
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      }.should raise_error(Treetop::Runtime::BytecodeLoadError, /undefined rule/)
    end

    it "rejects artifacts referencing unresolvable constants" do
      artifact = compile(<<~TREETOP)
        grammar BadConstant
          rule top
            'a' <DefinitelyNotDefinedAnywhere>
          end
        end
      TREETOP
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      }.should raise_error(Treetop::Runtime::BytecodeLoadError, /DefinitelyNotDefinedAnywhere/)
    end

    it "rejects artifacts with slot references out of range" do
      artifact = compile
      rule = artifact['rules'].find { |r| r['name'] == 'top' }
      save = rule['code'].find { |instruction| instruction[0] == :save_index }
      save[1] = 9999
      lambda {
        Treetop::Runtime::BytecodeLoader.load_artifact(artifact)
      }.should raise_error(Treetop::Runtime::BytecodeLoadError, /slot/)
    end

    it "installs the parser inside nested modules" do
      parser_class = load(<<~TREETOP)
        module LoaderOuter
          grammar NestedLoader
            rule top
              'a'
            end
          end
        end
      TREETOP
      LoaderOuter::NestedLoaderParser.should equal(parser_class)
      LoaderOuter::NestedLoader::Parser.should equal(parser_class)
      parser_class.new.parse('a').should_not be_nil
    end
  end
end
