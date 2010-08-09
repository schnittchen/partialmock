#Modify methods of one or more objects for the time of the current Test::Unit::TestCase
#test function.
#This is interesting to use in two situations:
#* Assert that a function (to be tested) has the side effect of invoking a method on a certain object
#  (it can even be asserted that a given call-sequences is taken).
#  This should probably not be used unless the side-effect method(s) can be tested independently.
#* Break up a recursive method and test the terminating case and the recursing case independently,
#  instead of (or in addition to) feeding fixtures to the method.

#To be used, PartialMock has to be set up with setup_for in a test or in the setup method.
#1. Define a template for a method definition using define_mockmeth.
#2. Hook the template onto a method using hook.
#3. Hook again or restore the original method.
#All method modifications will be reverted in the teardown method of the test case.
#Template definitions can use the original definition of a method, if hook has been used for it,
#using invoke_original.

module PartialMock

	#--
	class Caretaker #:nodoc:
		attr_reader :object

		@@ct_objects = {}
		def self.by_object(obj)
			@@ct_objects[obj.object_id]
		end

		#pattern could be e.g. "original <meth>": must contain "<meth>" and should contain a space
		#create only one per obj
		def initialize(obj, pattern)
			@object = obj
			@meta = class << obj; self; end
			@originals = {}
			@pattern = pattern
			@@ct_objects[obj.object_id] = self
		end

		#block will be evaluated in instance
		def hook(meth, &block)
			save_original(meth)
			@meta.instance_eval do
				begin
					remove_method meth
				rescue NameError
					#the method might be defined up in the inheritance chain
				end
				define_method(meth, &block)
			end
		end

		def invoke_backup(meth, *args)
			origmeth = @originals[meth]
			raise "invoke_backup called on method that has not been hooked" if origmeth.nil?
			@object.send(@originals[meth], *args)
		end

		def restore(meth)
			origmeth = @originals[meth]
			raise "restore called on method that has not been hooked" if origmeth.nil?
			@originals.delete meth
			@meta.instance_eval do
				begin
					remove_method meth
				rescue NameError
					#the method might be defined up in the inheritance chain
				end
				alias_method meth, origmeth
				remove_method origmeth
			end
		end

		#ct object must not be used after that
		def restore_all
			@originals.keys.each { |meth| restore(meth) }
			@@ct_objects.delete @object.object_id
		end

		private
		def save_original(meth)
			return if @originals.has_key?(meth)
			backup_name = @pattern.gsub("<meth>", meth.to_s)
			@meta.instance_eval do
				begin
					alias_method backup_name, meth
				rescue NameError => e
					raise "unknown method #{meth} (original message: #{e.message})"
				end
			end
			@originals[meth] = backup_name
		end
	end
	#++
	
	#Register the current TestCase object. Registering is necessary before
	#doing anything else. Pass the current Test::Unit::TestCase object, invoking
	#from inside a test or from inside tc's setup method (but not both).
	#
	#The registration is active until <code>wipe</code> is called. Registering will
	#alter tc's teardown method to eventually call wipe (wipe also undoes this).
	def self.setup_for(tc)
		raise "already setup for a TestCase object" unless @tcct.nil?
		@mocks = {}
		@caretakers = {}

		@tcct = Caretaker.new(tc, "original <meth>")
		@tcct.hook(:teardown) do
			#in the instance here
			tcct = PartialMock.instance_eval { @tcct }
			result = tcct.invoke_backup(:teardown)
			tcct.restore_all #explicitly restore TestCase method
			PartialMock.wipe
			result
		end
	end

	#Define the given block as a mock method.
	#
	#The block passed will be used to define a method __template__ that can later be hooked
	#(with <code>hook</code>)
	#onto other methods to mask the previous definition. Once hooked, block will be called
	#in the context of the caller, unless <code>in_instance == true</code> (in which case
	#it will be evaluated in the instance).
	#
	#<code>slot</code> is used as a hash key to be used at hook time.
	def self.define_mockmeth(slot, in_instance = false, &block)
		assert_registered
		raise "already have a mock method in slot #{slot}" if @mocks.has_key?(slot)
		@mocks[slot] = [block, in_instance]
	end

	#The object for which the current mockmeth is called.
	#Undefined if not inside a mock method with <code>in_instance == false</code>
	def self.current_object
		assert_registered
		@current_object
	end

	#The method the current mockmeth is replacing.
	#Undefined if not inside a mock method with <code>in_instance == false</code>
	def self.current_method
		assert_registered
		@current_method
	end

	#Hook mock method denoted by slot onto obj as method meth.
	#
	#Saves the original method internally the first time called
	#with the combination <code>[obj, meth]</code>.
	#In other words, hooking onto the same method of the same object more than once
	#does not alter the effect of invoke_backup and restore (and restore_all).
	def self.hook(slot, obj, meth)
		raise "unknown slot #{slot}" unless @mocks.has_key?(slot)
		ct = @caretakers[obj.object_id]
		ct = @caretakers[obj.object_id] = Caretaker.new(obj, "saved method <meth>") if ct.nil?

		block, in_instance = @mocks[slot]
		if in_instance then
			ct.hook(meth, &block)
		else
			obfusciated_block_variable = block #there will be no instance method with that name
			ct.hook(meth) do |*args|
				#we are in the instance obj now!
				sulf = self
				PartialMock.instance_eval do
					@current_object = sulf
					@current_method = __method__
				end

				begin
					obfusciated_block_variable.call(*args)
				ensure
					PartialMock.instance_eval do
						@current_object = nil
						@current_method = nil
					end
				end
			end
		end
	end

	#Invoke obj's original meth method. Inside that method, __<code>method__</code>
	#-- rdoc workaround above necessary?
	#++
	#(see kernel#__method__) will not equal meth!
	#Only possible if obj's method meth is hooked.
	def self.invoke_backup(obj, meth, *args)
		ct = @caretakers[obj.object_id]
		raise "invoke_backup called on method that has not been hooked" if ct.nil?
		ct.invoke_backup(meth, *args)
	end

	#Restore the original method.
	def self.restore(obj, meth)
		assert_registered
		ct = @caretakers[obj.object_id]
		raise "restore called on method that has not been hooked" if ct.nil?
		ct.restore(meth)
	end

	#Restore all original methods.
	def self.restore_all(obj)
		assert_registered
		ct = @caretakers[obj.object_id]
		@caretakers.delete obj.object_id
		raise "restore_all called for object without hooked methods" if ct.nil?
		ct.restore_all
	end

	#Obtain value from the module hash.
	#The hash is cleared on wipe (implicitly, in the teardown method of the TestCase)
	def self.[](ky)
		assert_registered
		@hash[ky]
	end

	#Store value into the module hash.
	#The hash is cleared on wipe (implicitly, in the teardown method of the TestCase)
	def self.[]=(ky, val)
		assert_registered
		@hash[ky] = val
	end

	#Reset module for next use:
	#* unregister TestCase object and restore its teardown method
	#* restore all original methods on objects hook was called for (for all methods not restored already)
	#* clear mock method slots
	#* clear module hash
	#To use the module again after wipe, use setup_for next.
	def self.wipe
		assert_registered
		@caretakers.each_value { |ct| ct.restore_all }
		
		clean_state
	end

	#Setup the wiped/unregistered state internally
	def self.clean_state
		@hash = {}
		@tcct = nil
		@mocks = nil
		@caretakers = nil
		@current_object = nil
		@current_method = nil
	end

	def self.assert_registered
		raise "not set up for a TestCase object" if @tcct.nil?
	end

	class << self
		private :clean_state
		private :assert_registered
	end

	clean_state
end #module PartialMock