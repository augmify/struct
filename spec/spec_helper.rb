# Must remain at the top of the file to properly track coverage
if ENV.key? 'CI'
	require 'coveralls'
	Coveralls.wear!
end

require 'semantic'
require 'tmpdir'
require 'yaml'
require_relative '../lib/spec/spec_file'
require_relative '../lib/create/create_class'
require_relative '../lib/create/create_configuration'
require_relative '../lib/create/create_struct'
require_relative '../lib/create/create_target'
require_relative '../lib/migrator/migrator'
require_relative '../lib/refresher/refresher'
require_relative '../lib/spec/parser/spec_parser'
require_relative '../lib/spec/parser/spec_parser_1_0_X'
require_relative '../lib/spec/parser/spec_parser_1_1_X'
require_relative '../lib/spec/writer/spec_writer'
require_relative '../lib/spec/writer/spec_writer_1_0_X'

RSpec.configure do |config|
	config.color = true
	config.tty = true
	original_stderr = $stderr
	original_stdout = $stdout
	config.before(:all) do
		# Redirect stderr and stdout
		$stderr = File.open(File::NULL, 'w')
		$stdout = File.open(File::NULL, 'w')
	end
	config.after(:all) do
		$stderr = original_stderr
		$stdout = original_stdout
	end
end
