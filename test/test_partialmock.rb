require 'test/unit'

require 'rubygems'
require 'ruby-debug'

#A helper for our test cases: by modifying setup, each test will use a fresh incarnation of the
#PartialMock module (we do metaprogramming manipulation during the tests, this helps to keep the modifications
#local to each individual test)
#In addition to that, post-initialization modifications can be defined
module TestHelper
	#this module is tested in TestTestHelper!

	MODS = {}

	#obtain a freshly defined PartialMock as partialmock.rb would produce it
	#called from setup wrapper
	def blank_module
		load "partialmock.rb", true #evaluate inside an anonymous module!

		#obtain the wrapped PartialMock module (see documentation of load) and
		#transplant it into the global namespace
		ObjectSpace.each_object(Module) do |mod|
			if /::PartialMock$/.match mod.name then
				#commented out, see below
# 					begin
# 						Object.remove_const("PartialMock") #otherwise, we get a warning below
# 					rescue NameError
# 					end
				#I cannot help that the line below gives a warning...
				Object.const_set("PartialMock", mod)
				return
			end
		end
		raise "could not find PartialMock!"
	end

	#called from setup wrapper
	def apply_modifications
		TestHelper::MODS.each_value { |block| block.call }
	end
	
	def self.included(tc)
		tc.class_eval do
			alias_method "old setup", :setup
			def setup
				blank_module
				apply_modifications
				send "old setup"
			end
		end
	end

	def self.define_modification(ky, &block)
		MODS[ky] = block
	end
end

class TestTestHelper < Test::Unit::TestCase
	#test TestHelper module since the tests rely on it

	DOESNOTNEED_TESTHELPER = true #this TestCase does not include TestHelper for obvious reasons

	class TestTestHelper_TCStub
		def setup
			23
		end

		def teardown
		end

		include TestHelper
	end

	def test_it
		tc = TestTestHelper_TCStub.new

		assert_equal(23, tc.setup)
		first_pm = PartialMock
		first_ct = PartialMock::Caretaker
		assert(!first_ct.nil?)
		tc.setup
		second_pm = PartialMock
		second_ct = PartialMock::Caretaker
		assert_not_same(first_pm, second_pm)
		assert_not_same(first_ct, second_ct)
		
		PartialMock.setup_for(tc)
		assert_same(second_ct, (second_pm.instance_eval { @tcct }).class) #be a little bit invasive here, just to be sure
	end
end

class TestCaretaker < Test::Unit::TestCase
	#test our internal workhorse, so there are no nasty surprises
	
	def test_registry
		o1 = Object.new
		o2 = Object.new
		ct1 = PartialMock::Caretaker.new(o1, "")
		ct2 = PartialMock::Caretaker.new(o2, "")
		
		assert_same(ct1, PartialMock::Caretaker.by_object(o1))
		assert_same(ct2, PartialMock::Caretaker.by_object(o2))
		
		ct1.restore_all
		assert_equal(nil, PartialMock::Caretaker.by_object(o1))
		
		#calling by_object for an unknown object is not defined, so we don't test
	end
	
	def run_callseq(object)
		#these variables bridge between mockproc and run_and_assert
		arguments_received = nil
		whatgotcalled = nil
		simulated_retval = nil
		
		#real and hooked implementations go through this
		#always pass the value of self for obj
		mockproc = lambda do |obj, gotcalled, *args|
			assert_equal(nil, arguments_received)
			arguments_received = args
			whatgotcalled = [obj, gotcalled]
			return simulated_retval
		end
		yield(mockproc) #tell caller how to implement methods
		
		ct = PartialMock::Caretaker.new(object, "original <meth>")
		
		last_retval = 51
		last_args = [0, 1]
		run_and_assert = lambda do |method, exp_gotcalled, invoke_backup|
			#prepare
			arguments_received = nil
			simulated_retval = last_retval
			args = last_args
			
			#invoke
			result = if invoke_backup then
				ct.invoke_backup(method, *args)
			else
				object.send(method, *args)
			end
			
			#assert
			assert_equal(args, arguments_received)
			assert_same(object, whatgotcalled[0])
			assert_equal(exp_gotcalled, whatgotcalled[1])
			assert_equal(simulated_retval, result)
			
			#prepare for next invocation
			last_retval *= last_retval
			last_args = last_args.collect { |arg| arg + 2 }
		end
		
		#invoke
		run_and_assert.call(:meth1, :meth1, false)
		
		#hook
		ct.hook(:meth1) { |*args| mockproc.call(self, :hook1, *args) }
		run_and_assert.call(:meth1, :hook1, false)
		
		#hook
		ct.hook(:meth1) { |*args| mockproc.call(self, :hook2, *args) }
		run_and_assert.call(:meth1, :hook2, false)
		
		#invoke backup
		run_and_assert.call(:meth1, :meth1, true)
		
		#restore
		ct.restore(:meth1)
		run_and_assert.call(:meth1, :meth1, false)

		#hook others
		ct.hook(:meth2) { |*args| mockproc.call(self, :hook2, *args) }
		ct.hook(:meth3) { |*args| mockproc.call(self, :hook3, *args) }
		run_and_assert.call(:meth2, :hook2, false)
		run_and_assert.call(:meth3, :hook3, false)
		
		#restore all
		ct.restore_all
		run_and_assert.call(:meth1, :meth1, false)
		run_and_assert.call(:meth2, :meth2, false)
		run_and_assert.call(:meth3, :meth3, false)
	end

	def test_callseq_simple_object
		o = Object.new
		
		class << o
			[:meth1, :meth2, :meth3].each do |meth|
				define_method(meth) do |*args|
					@mockproc.call(self, meth, *args)
				end
			end
		end
		
		run_callseq(o) do |proc|
			#obtained implementation mock proc
			o.instance_eval { @mockproc = proc }
		end
	end
	
	class Base
		def self.mockproc=(mp)
			@@mockproc = mp
		end
		
		[:meth1, :meth2, :meth3].each do |meth|
			define_method(meth) do |*args|
				@@mockproc.call(self, meth, *args)
			end
		end
	end
	
	class Derived < Base
	end
	
	def test_callseq_super_method
		o = Derived.new
		
		run_callseq(o) do |proc|
			#obtained implementation mock proc
			Base.mockproc = proc
		end
	end
	
	class Naked
	end
	
	def test_method_must_exist
		o = Naked.new
		
		ct = PartialMock::Caretaker.new(o, "original <meth>")
		
		assert_raise(RuntimeError) do
			ct.hook(:meth) { }
		end
		assert_raise(RuntimeError) { ct.restore(:meth) }
		assert_raise(RuntimeError) { ct.invoke_backup(:meth) }
	end
	
	class Simple
		def meth
		end
	end
	
	def test_method_must_be_hooked
		#for restore and invoke_backup
		o = Simple.new
		
		ct = PartialMock::Caretaker.new(o, "original <meth>")
		
		assert_raise(RuntimeError) { ct.restore(:meth) }
		assert_raise(RuntimeError) { ct.invoke_backup(:meth) }
	end

	include TestHelper
end

TestHelper.define_modification(:ct_restoreall) do
	#no method must be called on a Caretaker object after restore_all.
	#the mechanism below guarantees our tests blow up if the implementation
	#does not obey this
	#
	#this blowing up is tested in Test_Caretaker_extension
	
	PartialMock::Caretaker.class_eval do
		#we use this to see that the removal in restore_all works
		#and to check the retval is recorded
		def nop
			47
		end

		alias_method "saved restore_all", :restore_all
		def restore_all
			send("saved restore_all")
			class << self
				#remove all methods
				instance_methods(false).each do |meth|
					#don't remove_method here, method not defined in meta class!
					undef_method meth
				end

				def method_missing(*args)
					raise "someone is using this object after a call to restore_all!"
				end
				freeze
			end
		end
	end
end

class Test_Caretaker_extension < Test::Unit::TestCase
	class Cls
		def meth
		end
	end
	
	def test_it
		o = Cls.new
		ct = PartialMock::Caretaker.new(o, "saved <meth>")
		
		ct.nop
		ct.restore_all
		assert_raise(RuntimeError) { ct.nop }
	end

	include TestHelper
end

#class for Test::Unit::TestCase stubs
class TestCase_Stub
	def teardown
		42
	end
end

class Test_cornercases < Test::Unit::TestCase
	#test that calling setup_for twice raises an exception
	def test_setupfor_twice
		tc = TestCase_Stub.new
		
		PartialMock.setup_for(tc)
		assert_raise(RuntimeError) { PartialMock.setup_for(tc) }
	end

	#test that define_mockmeth can only be called once for a slot
	def test_slot_only_once
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)

		PartialMock.define_mockmeth(:slot) { }
		assert_raise(RuntimeError) { PartialMock.define_mockmeth(:slot) { } }
	end

	class Target
		def known_method
		end
	end

	def test_hook_slot_and_method_must_exist
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		o = Target.new
		PartialMock.define_mockmeth(:known_slot) { }
		
		assert_raise(RuntimeError) do
			PartialMock.hook(:unknown_slot, o, :known_method)
		end
		assert_raise(RuntimeError) do
			PartialMock.hook(:known_slot, o, :unknown_method)
		end
	end

	def test_invokebackup_and_restore_need_hooked
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		
		PartialMock.define_mockmeth(:known_slot) { }
		obj = Target.new
		
		assert_raise(RuntimeError) do
			PartialMock.invoke_backup(obj, :known_method)
		end

		assert_raise(RuntimeError) do
			PartialMock.restore(obj, :known_method)
		end
	end

	def do_setup_needed_assertions
		assert_raise(RuntimeError) do
			PartialMock.define_mockmeth(:slot) { }
		end
		#no need to check hook: indistinguishable from the case of an unknown slot, already tested
		#no need to check invoke_backup and restore for similar reasons
		assert_raise(RuntimeError) { PartialMock.restore_all(Object.new) }
		assert_raise(RuntimeError) { PartialMock.current_object }
		assert_raise(RuntimeError) { PartialMock.current_method }
		assert_raise(RuntimeError) { PartialMock[:key] = :value }
		assert_raise(RuntimeError) { PartialMock[:key] }
		assert_raise(RuntimeError) { PartialMock.wipe }
	end
	
	def test_setup_needed_initially
		do_setup_needed_assertions
	end
	
	def test_setup_needed_after_wipe
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		PartialMock.wipe
		do_setup_needed_assertions
	end

	def test_hash_empty_after_wipe
		tc1, tc2 = TestCase_Stub.new, TestCase_Stub.new
		PartialMock.setup_for(tc1)
		
		PartialMock[:key] = :value
		
		PartialMock.wipe #this will not remove the old teardown original, which happens only when the wrapping
		#teardown itself is invoked. Therefore, setup_for(the same stub object) would give a warning
		#that the original teardown backup is overwritten
		PartialMock.setup_for(tc2)
		
		assert_equal(nil, PartialMock[:key]) #test we did not do something really stupid
	end
	
	include TestHelper
end

class Test_mainfeature < Test::Unit::TestCase
	#test "scope" (arguments, return value, value of self and retval of current_method and current_object, if appropriate)
	#for hooked blocks (in_instance true and false) and for invoke_backup.
	#also, excercise a call sequence of hook, method invocation, invoke_original, restore, restore_all and wipe,
	#testing that method invocation and invoke_original end up in the right block

	class Target
		class << self
			attr_accessor :running_tc, :instance
		end
		
		def meth(a, b, c)
			@@tc.flunk
		end

		def meth1(a, b)
			[self, :meth1, a, b]
		end
		
		def meth2(a, b)
			[self, :meth2, a, b]
		end
	end
	
	def test_scope_in_hook_invocation
		#preparation
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		
		Target.running_tc = self
		obj = Target.new
		Target.instance = obj

		#test with in_instance == false
		solf = self
		PartialMock.define_mockmeth(:slot_notininstance) do |*args|
			assert_equal([0, 1, 2], args)
			assert_same(solf, self)
			
			assert_same(obj, PartialMock.current_object)
			assert_equal(:meth, PartialMock.current_method)
			
			7
		end
		
		PartialMock.hook(:slot_notininstance, obj, :meth)
		assert_equal(7, obj.meth(0, 1, 2))

		#test with in_instance == true
		PartialMock.define_mockmeth(:slot_ininstance, true) do |*args|
			rtc = Target.running_tc
			rtc.assert_same(Target.instance, self)
			rtc.assert_equal([0, 1, 2], args)
			11
		end
		
		PartialMock.hook(:slot_ininstance, obj, :meth)
		assert_equal(11, obj.meth(0, 1, 2))
	end

	def test_scope_in_invoke_backup
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		
		obj1 = Target.new
		obj2 = Target.new
		
		PartialMock.define_mockmeth(:slot) { |*args| }
		
		PartialMock.hook(:slot, obj1, :meth1)
		PartialMock.hook(:slot, obj2, :meth2)
		
		assert_equal([obj1, :meth1, 0, 1], PartialMock.invoke_backup(obj1, :meth1, 0, 1))
		assert_equal([obj2, :meth2, 2, 3], PartialMock.invoke_backup(obj2, :meth2, 2, 3))
	end

	class CallseqTarget
		def self.register_defblock(&block)
			@@defblock = block
		end
		
		def meth1
			@@defblock.call(self, :meth1)
		end
		
		def meth2
			@@defblock.call(self, :meth2)
		end
		
		def meth3
			@@defblock.call(self, :meth3)
		end
		
		def meth4
			@@defblock.call(self, :meth4)
		end
	end
	
	def expect_inv(obj, sym, slot = nil)
		@exinv = [obj, sym, slot]
		yield
		assert_equal(nil, @exinv) #got_inv got called
	end
	
	def got_inv(obj, sym, slot = nil)
		assert_equal([obj, sym, slot], @exinv)
		@exinv = nil
	end
	
	def test_callseq
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		
		CallseqTarget.register_defblock do |obj, sym|
			got_inv(obj, sym)
		end
		
		obj1 = CallseqTarget.new
		obj2 = CallseqTarget.new
		
		PartialMock.define_mockmeth(:slot1) do |*args|
			got_inv(PartialMock.current_object, PartialMock.current_method, :slot1)
		end
		
		PartialMock.define_mockmeth(:slot2) do |*args|
			got_inv(PartialMock.current_object, PartialMock.current_method, :slot2)
		end

		#this callseq is probably over-exhaustive...
		
		#what will happen: (notice distinction between original and backup)
		PartialMock.hook(:slot1, obj1, :meth1) #invoke
		PartialMock.hook(:slot2, obj1, :meth2) #invoke and invoke backup, restore twice and invoke original
		PartialMock.hook(:slot1, obj1, :meth3) #invoke
		PartialMock.hook(:slot2, obj1, :meth4) #invoke
		#restore all on obj1 and invoke all four originals
		PartialMock.hook(:slot2, obj2, :meth1) #invoke, re-hook, re-hook, invoke_backup
		PartialMock.hook(:slot2, obj2, :meth2) #invoke
		PartialMock.hook(:slot1, obj2, :meth3) #invoke
		PartialMock.hook(:slot1, obj2, :meth4) #invoke
		#wipe and invoke all four originals on obj2
		
		expect_inv(obj1, :meth1, :slot1) { obj1.meth1 }
		
		expect_inv(obj1, :meth2, :slot2) { obj1.meth2 }
		expect_inv(obj1, :meth2) { PartialMock.invoke_backup(obj1, :meth2) }
		PartialMock.restore(obj1, :meth2)
		assert_raise(RuntimeError) { PartialMock.restore(obj1, :meth2) }
		expect_inv(obj1, :meth2) { obj1.meth2 }
		assert_raise(RuntimeError) { PartialMock.invoke_backup(obj1, :meth2) }
		
		expect_inv(obj1, :meth3, :slot1) { obj1.meth3 }
		
		expect_inv(obj1, :meth4, :slot2) { obj1.meth4 }
		
		PartialMock.restore_all(obj1)
		
		expect_inv(obj1, :meth1) { obj1.meth1 }
		
		expect_inv(obj1, :meth2) { obj1.meth2 }
		
		expect_inv(obj1, :meth3) { obj1.meth3 }
		
		expect_inv(obj1, :meth4) { obj1.meth4 }
		
		
		expect_inv(obj2, :meth1, :slot2) { obj2.meth1 }
		PartialMock.hook(:slot1, obj2, :meth1)
		expect_inv(obj2, :meth1, :slot1) { obj2.meth1 }
		PartialMock.hook(:slot2, obj2, :meth1)
		expect_inv(obj2, :meth1, :slot2) { obj2.meth1 }
		expect_inv(obj2, :meth1) { PartialMock.invoke_backup(obj2, :meth1) }
		
		expect_inv(obj2, :meth2, :slot2) { obj2.meth2 }
		
		expect_inv(obj2, :meth3, :slot1) { obj2.meth3 }
		
		expect_inv(obj2, :meth4, :slot1) { obj2.meth4 }
		
		PartialMock.wipe
		
		expect_inv(obj2, :meth1) { obj2.meth1 }
		
		expect_inv(obj2, :meth2) { obj2.meth2 }
		
		expect_inv(obj2, :meth3) { obj2.meth3 }
		
		expect_inv(obj2, :meth4) { obj2.meth4 }
	end
	
	include TestHelper
end

class Test_Hashlike < Test::Unit::TestCase
	def test_it
		tc = TestCase_Stub.new
		PartialMock.setup_for(tc)
		
		PartialMock[:key1] = 1
		PartialMock[:key2] = 2
		
		assert_equal(1, PartialMock[:key1])
		assert_equal(1, PartialMock[:key1])
		assert_equal(2, PartialMock[:key2])
	end
	
	include TestHelper
end

class Test_setup_teardown_hooking < Test::Unit::TestCase
	#test that PartialMock.wipe is called from modified teardown, and that
	#modified teardown invokes the original one
	#We can assume that Caretaker has been tested above, so we use it here

	def test_it
		#prepare mechanism: wrap PartialMock.wipe
		pmct = PartialMock::Caretaker.new(PartialMock, "original <meth>")
		pmct.hook(:wipe) do
			PartialMock::WipeBlock.call
		end

		#test mechanism
		hit = false
		PartialMock.const_set("WipeBlock", Proc.new do
			hit = true
		end)
		PartialMock.wipe
		assert(hit)

		#prepare and run test
		tc = TestCase_Stub.new

		PartialMock.const_set("WipeBlock", Proc.new do
			flunk
		end)
		PartialMock.setup_for(tc)

		hit = false
		PartialMock.const_set("WipeBlock", Proc.new do
			hit = true
		end)
		assert_equal(42, tc.teardown) #assert result: did call original teardown
		assert(hit) #did call wipe
	end
	
	include TestHelper
end

#ensure that all our TestCase classes include TestHelper
ObjectSpace.each_object(Class) do |cls|
	if cls < Test::Unit::TestCase then
		if !(cls <= TestHelper) then
			raise "TestCase class #{cls} should include TestHelper!" unless
				cls.const_defined?("DOESNOTNEED_TESTHELPER")
		end
	end
end