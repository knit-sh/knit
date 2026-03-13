require 'simplecov'
require 'simplecov-cobertura'

SimpleCov.formatter = SimpleCov::Formatter::CoberturaFormatter

SimpleCov.start do
  add_filter '/tests/'
  track_files 'src/**/*.sh'
end
