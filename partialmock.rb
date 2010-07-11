module PartialMock

	#Register the current TestCase object. Call this from inside tc's setup method.
	#This will modify tc's teardown method to call wipe.
	def self.setup_for(tc)
	end

	#Define the given block as a mock method.
	#Denote it by slot, which can be any object.
	#If in_instance is true, block will be evaluated in the instance the mock method has
	#been hooked onto.
	def self.define_mockmeth(slot, in_instance = false, &block)
	end

	#The object for which the current mockmeth is called.
	#Only valid in the case in_instance == false.
	def self.current_object
	end

	#The method the current mockmeth is replacing.
	#Only valid in the case in_instance == false.
	def self.current_method
	end

	#Hook mock method denoted by slot onto obj as method meth.
	#Saves the original method internally the first time called with the combination [obj, meth].
	#If restore is true, the original method will be restored immediately prior to
	#executing the mock method.
	def self.hook(slot, obj, meth, restore = false)
	end

	#Invoke obj's original meth method. Inside that method, __method__ will not equal meth!
	#Only possible if obj's method meth is hooked.
	def self.invoke_backup(obj, meth, *args)
	end

	#Restore the original method.
	def self.restore(obj, meth)
	end

	#Restore all original methods.
	def self.restore_all(obj)
	end

	#Obtain value from module hash.
	def self.[](ky)
	end

	#Store value into module hash.
	def self.[]=(ky, val)
	end

	#Reset module for next use:
	#* unregister TestCase object and restore its teardown method
	#* restore all original methods on objects hook was called for (for all methods not restored already)
	#* clear mock method slots
	#* clear module hash
	def self.wipe
	end
end #module PartialMock