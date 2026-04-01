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
    # Probe RefrigerationCase constructor signature and setter methods
    rc = OpenStudio::Model::RefrigerationCase.new(model, model.alwaysOnDiscreteSchedule)
    rc_setters = rc.methods.map(&:to_s).select { |m| m.start_with?('set') }.sort
    runner.registerInfo("Case setters: #{rc_setters.join(', ')}")

    # Probe RefrigerationWalkIn constructor signature and setter methods
    wi = OpenStudio::Model::RefrigerationWalkIn.new(model, model.alwaysOnDiscreteSchedule)
    wi_setters = wi.methods.map(&:to_s).select { |m| m.start_with?('set') }.sort
    runner.registerInfo("WalkIn setters: #{wi_setters.join(', ')}")

    runner.registerFinalCondition("Probed Case (#{rc_setters.size}) and WalkIn (#{wi_setters.size}) setter methods")
    true
# --- end user logic ---
    return true
  end
end

ProbeCondenserApi.new.registerWithApplication
