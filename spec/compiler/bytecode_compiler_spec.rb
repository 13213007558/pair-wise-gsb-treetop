require 'spec_helper'

module BytecodeCompilerSpec
  describe Treetop::Compiler::BytecodeCompiler do
    def compile(source)
      Treetop::Compiler::BytecodeCompiler.new.compile_to_artifact(source)
    end

    def compiling(source)
      lambda { compile(source) }
    end

    it "produces a versioned artifact describing the grammar" do
      artifact = compile("grammar Versioned\n  rule a\n    'a'\n  end\nend\n")
      artifact['format'].should == 'treetop-bytecode'
      artifact['version'].should == Treetop::Compiler::BytecodeCompiler::VERSION
      artifact['version'].should == Treetop::Runtime::BytecodeLoader::FORMAT_VERSION
      artifact['treetop_version'].should == Treetop::VERSION::STRING
      artifact['grammar_name'].should == 'Versioned'
      artifact['root'].should == 'a'
      artifact['rules'].map { |rule| rule['name'] }.should == ['a']
    end

    it "records the enclosing module path of a grammar" do
      artifact = compile("module Outer\n  module Inner\n    grammar Nested\n      rule a\n        'a'\n      end\n    end\n  end\nend\n")
      artifact['module_path'].should == [['Outer', 'module'], ['Inner', 'module']]
      artifact['grammar_name'].should == 'Nested'
    end

    it "collects node class references into a constant table" do
      artifact = compile("grammar WithNodeClass\n  rule a\n    'a' <String>\n  end\nend\n")
      artifact['constants'].should == ['String']
    end

    it "collects sequence labels into accessor tables" do
      artifact = compile("grammar Labeled\n  rule a\n    first:'a' rest:'b'*\n  end\nend\n")
      artifact['accessors'].should == [{ 'first' => 0, 'rest' => 1 }]
    end

    it "rejects semantic predicates, which embed Ruby code" do
      compiling("grammar Bad\n  rule a\n    &{ true } 'a'\n  end\nend\n").should raise_error(Treetop::Compiler::UnsupportedFeatureError, /semantic predicate/)
    end

    it "rejects inline modules, which embed Ruby code" do
      compiling("grammar Bad\n  rule a\n    'a' { def foo; end }\n  end\nend\n").should raise_error(Treetop::Compiler::UnsupportedFeatureError, /inline module/)
    end

    it "rejects super, which relies on generated Ruby methods" do
      compiling("grammar Bad\n  rule a\n    super\n  end\nend\n").should raise_error(Treetop::Compiler::UnsupportedFeatureError, /super/)
    end

    it "rejects include declarations" do
      compiling("grammar Bad\n  include Enumerable\n  rule a\n    'a'\n  end\nend\n").should raise_error(Treetop::Compiler::UnsupportedFeatureError, /include/)
    end

    it "rejects node class declarations that are not constant paths" do
      compiling("grammar Bad\n  rule a\n    'a' <foo.bar>\n  end\nend\n").should raise_error(Treetop::Compiler::UnsupportedFeatureError, /constant path/)
    end
  end
end
