require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require_relative '../measure'

class ApplySupermarketRefrigerationTest < Minitest::Test
  def load_test_model
    test_model = File.join(File.dirname(__FILE__), 'test_model.osm')
    if File.exist?(test_model)
      vt = OpenStudio::OSVersion::VersionTranslator.new
      model = vt.loadModel(OpenStudio::Path.new(test_model))
      return model.get if model.is_initialized
    end
    OpenStudio::Model::Model.new
  end

  def test_number_of_arguments
    measure = ApplySupermarketRefrigeration.new
    model = load_test_model
    arguments = measure.arguments(model)
    assert_equal(1, arguments.size)
  end

  def test_good_argument_values
    measure = ApplySupermarketRefrigeration.new
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)
    model = load_test_model
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    args_hash = {}
    args_hash['json_path'] = '/runs/SuperMarket_advanced_refrigeration_system.json'
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end
    measure.run(model, runner, argument_map)
    result = runner.result
    result.showOutput
    assert_equal('Success', result.value.valueName)
  end
end
