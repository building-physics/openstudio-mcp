class ProbeCondenserApi < OpenStudio::Measure::ModelMeasure
  def name
    return "Probe Condenser Api"
  end

  def description
    return "Probe available setter methods on RefrigerationCondenserAirCooled in OS 3.11"
  end

  def modeler_description
    return "Probe available setter methods on RefrigerationCondenserAirCooled in OS 3.11"
  end

  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new
    return args
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
    # --- begin user logic ---
    cond = OpenStudio::Model::RefrigerationCondenserAirCooled.new(model)
    set_methods = cond.methods.map(&:to_s).select { |m| m.start_with?('set') }.sort
    runner.registerInfo("AirCooled condenser setters: #{set_methods.join(', ')}")
    runner.registerFinalCondition("Found #{set_methods.size} setter methods on RefrigerationCondenserAirCooled")
    true
    # --- end user logic ---
    return true
  end
end

ProbeCondenserApi.new.registerWithApplication
