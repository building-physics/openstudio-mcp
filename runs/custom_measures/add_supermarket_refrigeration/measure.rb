class AddSupermarketRefrigeration < OpenStudio::Measure::ModelMeasure
  def name
    return "Add Supermarket Refrigeration"
  end

  def description
    return "Applies an advanced supermarket refrigeration system from a JSON file to the OpenStudio model, adding compressors, condensers, display cases, and walk-in coolers/freezers."
  end

  def modeler_description
    return "Applies an advanced supermarket refrigeration system from a JSON file to the OpenStudio model, adding compressors, condensers, display cases, and walk-in coolers/freezers."
  end

  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new
    json_path = OpenStudio::Measure::OSArgument.makeStringArgument("json_path", true)
    json_path.setDisplayName("Refrigeration JSON Path")
    json_path.setDescription("Absolute path to the supermarket refrigeration system JSON file")
    json_path.setDefaultValue("/runs/SuperMarket_advanced_refrigeration_system.json")
    args << json_path
    return args
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
    json_path = runner.getStringArgumentValue("json_path", user_arguments)
    # --- begin user logic ---
    require 'json'

    unless File.exist?(json_path)
      runner.registerError("JSON file not found: #{json_path}")
      return false
    end

    data = JSON.parse(File.read(json_path))
    objects = data['objects'] || []
    runner.registerInitialCondition("Loading #{objects.size} refrigeration objects from #{File.basename(json_path)}")

    created = {}

    # Helper: set bicubic curve coefficients using all available setter names
    def set_bicubic(model, name, obj)
      c = OpenStudio::Model::CurveBicubic.new(model)
      c.setName(name)
      c.setCoefficient1Constant(obj['Coefficient1Constant'].to_f)
      c.setCoefficient2x(obj['Coefficient2x'].to_f)
      c.setCoefficient3xPOW2(obj['Coefficient3x2'].to_f)
      c.setCoefficient4y(obj['Coefficient4y'].to_f)
      c.setCoefficient5yPOW2(obj['Coefficient5y2'].to_f)
      c.setCoefficient6xTIMESY(obj['Coefficient6xy'].to_f)
      c.setCoefficient7xPOW3(obj['Coefficient7x3'].to_f)
      # Coefficients 8-10 — method names differ by OS version
      ['setCoefficient8xPOW2TIMESY','setCoefficient8xPow2TIMESY','setCoefficient8x2TIMESY'].each do |m|
        begin; c.send(m, obj['Coefficient8x2y'].to_f); break; rescue; end
      end
      ['setCoefficient9xTIMESYPOW2','setCoefficient9xTIMESYPow2','setCoefficient9xTIMESY2'].each do |m|
        begin; c.send(m, obj['Coefficient9xy2'].to_f); break; rescue; end
      end
      ['setCoefficient10yPOW3','setCoefficient10yPow3','setCoefficient10y3'].each do |m|
        begin; c.send(m, obj['Coefficient10y3'].to_f); break; rescue; end
      end
      c.setMinimumValueofx(obj['MinimumValueofx'].to_f)
      c.setMaximumValueofx(obj['MaximumValueofx'].to_f)
      c.setMinimumValueofy(obj['MinimumValueofy'].to_f)
      c.setMaximumValueofy(obj['MaximumValueofy'].to_f)
      c
    end

    # Pass 1: zones, curves, compressors, condensers
    objects.each do |obj|
      type = obj['type']
      name = obj['name']

      case type
      when 'OS:ThermalZone'
        z_opt = model.getThermalZoneByName(name)
        if z_opt.is_initialized
          created[name] = z_opt.get
          runner.registerInfo("Found zone: #{name}")
        else
          runner.registerWarning("Zone not found: #{name}")
        end

      when 'OS:Curve:Bicubic'
        created[name] = set_bicubic(model, name, obj)

      when 'OS:Curve:Linear'
        c = OpenStudio::Model::CurveLinear.new(model)
        c.setName(name)
        c.setCoefficient1Constant(obj['Coefficient1Constant'].to_f)
        c.setCoefficient2x(obj['Coefficient2x'].to_f)
        c.setMinimumValueofx(obj['MinimumValueofx'].to_f)
        c.setMaximumValueofx(obj['MaximumValueofx'].to_f)
        created[name] = c

      when 'OS:Refrigeration:Compressor'
        comp = OpenStudio::Model::RefrigerationCompressor.new(model)
        comp.setName(name)
        pwr_curve_name = obj['CompressorCurve']
        if pwr_curve_name && created[pwr_curve_name]
          comp.setRefrigerationCompressorPowerCurve(created[pwr_curve_name])
        end
        cap_curve_name = pwr_curve_name&.gsub('_Pwr_', '_Cap_')&.gsub('Pwr', 'Cap')
        if cap_curve_name && created[cap_curve_name]
          comp.setRefrigerationCompressorCapacityCurve(created[cap_curve_name])
        end
        created[name] = comp

      when 'OS:Refrigeration:Condenser:AirCooled'
        cond = OpenStudio::Model::RefrigerationCondenserAirCooled.new(model)
        cond.setName(name)
        created[name] = cond
      end
    end

    # Pass 2: cases and walk-ins
    objects.each do |obj|
      type = obj['type']
      name = obj['name']

      case type
      when 'OS:Refrigeration:Case'
        zone_name = obj['ZoneName']
        zone = created[zone_name]
        unless zone
          z_opt = model.getThermalZoneByName(zone_name)
          zone = z_opt.get if z_opt.is_initialized
        end
        next unless zone
        rc = OpenStudio::Model::RefrigerationCase.new(model, model.alwaysOnDiscreteSchedule, zone)
        rc.setName(name)
        rc.setCaseLength(obj['CaseLength'].to_f) if obj['CaseLength']
        rc.setCaseOperatingTemperature(obj['OperatingTemperature'].to_f) if obj['OperatingTemperature']
        created[name] = rc
        runner.registerInfo("Created case: #{name}")

      when 'OS:Refrigeration:WalkIn'
        zone_name = obj['ZoneName']
        zone = created[zone_name]
        unless zone
          z_opt = model.getThermalZoneByName(zone_name)
          zone = z_opt.get if z_opt.is_initialized
        end
        next unless zone
        wi = OpenStudio::Model::RefrigerationWalkIn.new(model, model.alwaysOnDiscreteSchedule)
        wi.setName(name)
        wi.setRatedCoolingCapacity(obj['RatedCoolingCapacity'].to_f) if obj['RatedCoolingCapacity']
        wi.setOperatingTemperature(obj['OperatingTemperature'].to_f) if obj['OperatingTemperature']
        created[name] = wi
        runner.registerInfo("Created walk-in: #{name}")
      end
    end

    # Pass 3: systems
    objects.each do |obj|
      type = obj['type']
      name = obj['name']
      next unless type == 'OS:Refrigeration:System'
      sys = OpenStudio::Model::RefrigerationSystem.new(model)
      sys.setName(name)
      (obj['Compressors'] || []).each { |cn| comp = created[cn]; sys.addCompressor(comp) if comp }
      cond = created[obj['Condenser'].to_s]
      sys.setRefrigerationCondenser(cond) if cond
      (obj['Cases'] || []).each { |cn| rc = created[cn]; sys.addCase(rc) if rc }
      (obj['WalkIns'] || []).each { |wn| wi = created[wn]; sys.addWalkin(wi) if wi }
      created[name] = sys
      runner.registerInfo("Created refrigeration system: #{name}")
    end

    n_comp   = model.getRefrigerationCompressors.size
    n_case   = model.getRefrigerationCases.size
    n_walkin = model.getRefrigerationWalkIns.size
    n_sys    = model.getRefrigerationSystems.size

    runner.registerFinalCondition(
      "Refrigeration added: #{n_comp} compressors, #{n_case} cases, " \
      "#{n_walkin} walk-ins, #{n_sys} systems"
    )
    true
# --- end user logic ---
    return true
  end
end

AddSupermarketRefrigeration.new.registerWithApplication
