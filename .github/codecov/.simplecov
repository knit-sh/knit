require 'simplecov'
require 'simplecov-cobertura'

SimpleCov.formatter = SimpleCov::Formatter::CoberturaFormatter

# Only track coverage for our source files
SimpleCov.start do
  add_filter '/tests/'
  track_files 'knit.sh'
end
