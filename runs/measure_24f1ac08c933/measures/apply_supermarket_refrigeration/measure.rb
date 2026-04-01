class ApplySupermarketRefrigeration < OpenStudio::Measure::ModelMeasure
  def name
    return "Apply Supermarket Refrigeration"
  end

  def description
    return "Loads a supermarket refrigeration system from an OpenStudio JSON file and applies compressors, condensers, display cases, and walk-in coolers/freezers to the model."
  end

  def modeler_description
    return "Loads a supermarket refrigeration system from an OpenStudio JSON file and applies compressors, condensers, display cases, and walk-in coolers/freezers to the model."
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

    json_path_val = json_path
    unless File.exist?(json_path_val)
      runner.registerError("Refrigeration JSON not found: #{json_path_val}")
      return false
    end

    data = JSON.parse(File.read(json_path_val))
    objects = data['objects'] || []

    runner.registerInitialCondition("Loading #{objects.size} refrigeration objects")

    # Collect existing thermal zones; create fallback zones if needed
    zone_map = {}
    model.getThermalZones.each { |z| zone_map[z.name.to_s] = z }
    # Use the first sales-related zone as MainSales fallback
    sales_zone = zone_map.values.find { |z| z.name.to_s.downcase.include?('sales') } ||
                 zone_map.values.find { |z| z.name.to_s.downcase.include?('retail') } ||
                 zone_map.values.first
    storage_zone = zone_map.values.find { |z| z.name.to_s.downcase.include?('storage') } ||
                   zone_map.values.find { |z| z.name.to_s.downcase.include?('back') } ||
                   sales_zone

    zone_map['MainSales']     ||= sales_zone
    zone_map['ActiveStorage'] ||= storage_zone

    # Build Linear curves
    curve_map = {}
    objects.select { |o| o['type'] == 'OS:Curve:Linear' }.each do |obj|
      c = OpenStudio::Model::CurveLinear.new(model)
      c.setName(obj['name'])
      c.setCoefficient1Constant(obj['Coefficient1Constant'].to_f)
      c.setCoefficient2x(obj['Coefficient2x'].to_f)
      c.setMinimumValueofx(obj['MinimumValueofx'].to_f)
      c.setMaximumValueofx(obj['MaximumValueofx'].to_f)
      curve_map[obj['name']] = c
    end
    runner.registerInfo("Created #{curve_map.size} curves")

    # Build compressors
    compressor_map = {}
    objects.select { |o| o['type'] == 'OS:Refrigeration:Compressor' }.each do |obj|
      comp = OpenStudio::Model::RefrigerationCompressor.new(model)
      comp.setName(obj['name'])
      compressor_map[obj['name']] = comp
    end
    runner.registerInfo("Created #{compressor_map.size} compressors")

    # Group compressors into racks
    mt_racks = {}
    lt_racks = {}
    compressor_map.each do |name, comp|
      parts = name.split('_')
      next unless parts.size >= 4
      rack_type = parts[1]
      rack_key  = parts[2]
      if rack_type == 'MT'
        mt_racks[rack_key] ||= []
        mt_racks[rack_key] << comp
      elsif rack_type == 'LT'
        lt_racks[rack_key] ||= []
        lt_racks[rack_key] << comp
      end
    end

    # Build condensers — only verified OS 3.11 setters
    condenser_map = {}
    all_condensers = []
    objects.select { |o| o['type'] == 'OS:Refrigeration:Condenser:AirCooled' }.each do |obj|
      cond = OpenStudio::Model::RefrigerationCondenserAirCooled.new(model)
      cond.setName(obj['name'])
      cond.setRatedSubcoolingTemperatureDifference(obj['RatedSubcoolingTemperatureDifference'].to_f) if obj['RatedSubcoolingTemperatureDifference']
      cond.setRatedFanPower(obj['RatedFanPower'].to_f) if obj['RatedFanPower']
      condenser_map[obj['name']] = cond
      all_condensers << cond
    end
    runner.registerInfo("Created #{condenser_map.size} condensers")

    # Build MT refrigeration systems
    mt_rack_count = 0
    condenser_index = 0
    mt_racks.each do |rack_key, comps|
      cond = condenser_map["MT_#{rack_key}_Condenser"] ||
             condenser_map["#{rack_key}_Condenser"] ||
             all_condensers[condenser_index % all_condensers.size]
      condenser_index += 1
      next unless cond
      rack = OpenStudio::Model::RefrigerationSystem.new(model)
      rack.setName("MT_#{rack_key}")
      rack.setRefrigerationCondenser(cond)
      rack.setSumUASuctionPiping(0.0)
      comps.each { |c| rack.addCompressor(c) }
      mt_rack_count += 1
    end

    # Build LT refrigeration systems
    lt_rack_count = 0
    lt_racks.each do |rack_key, comps|
      cond = condenser_map["LT_#{rack_key}_Condenser"] ||
             all_condensers[condenser_index % all_condensers.size]
      condenser_index += 1
      next unless cond
      rack = OpenStudio::Model::RefrigerationSystem.new(model)
      rack.setName("LT_#{rack_key}")
      rack.setRefrigerationCondenser(cond)
      rack.setSumUASuctionPiping(0.0)
      comps.each { |c| rack.addCompressor(c) }
      lt_rack_count += 1
    end
    runner.registerInfo("Created #{mt_rack_count} MT racks, #{lt_rack_count} LT racks")

    # Build display cases — OS 3.11: RefrigerationCase.new(model, defrost_schedule)
    # Zone assigned via setThermalZone; fan via setOperatingCaseFanPowerperUnitLength
    case_count = 0
    objects.select { |o| o['type'] == 'OS:Refrigeration:Case' }.each do |obj|
      zone_name = obj['ZoneName'] || 'MainSales'
      zone = zone_map[zone_name] || zone_map['MainSales'] || zone_map.values.first
      next unless zone
      rc = OpenStudio::Model::RefrigerationCase.new(model, model.alwaysOnDiscreteSchedule)
      rc.setName(obj['name'])
      rc.setThermalZone(zone)
      rc.setCaseLength(obj['CaseLength'].to_f)                                                         if obj['CaseLength']
      rc.setCaseOperatingTemperature(obj['OperatingTemperature'].to_f)                                 if obj['OperatingTemperature']
      rc.setDesignEvaporatorTemperatureorBrineInletTemperature(obj['EvaporatorTemperature'].to_f)      if obj['EvaporatorTemperature']
      rc.setRatedLatentHeatRatio(obj['RatedLatentHeatRatio'].to_f)                                    if obj['RatedLatentHeatRatio']
      rc.setRatedRuntimeFraction(obj['RatedRuntimeFraction'].to_f)                                    if obj['RatedRuntimeFraction']
      rc.setOperatingCaseFanPowerperUnitLength(obj['FanPowerPerUnitLength'].to_f)                     if obj['FanPowerPerUnitLength']
      rc.setInstalledCaseLightingPowerperUnitLength(obj['LightingPowerPerUnitLength'].to_f)           if obj['LightingPowerPerUnitLength']
      case_count += 1
    end
    runner.registerInfo("Created #{case_count} display cases")

    # Build walk-ins — OS 3.11: zone boundary via flat setZoneBoundary* setters
    walkin_count = 0
    objects.select { |o| o['type'] == 'OS:Refrigeration:WalkIn' }.each do |obj|
      zone_name = obj['ZoneName'] || 'ActiveStorage'
      zone = zone_map[zone_name] || zone_map['ActiveStorage'] || zone_map.values.first
      next unless zone
      wi = OpenStudio::Model::RefrigerationWalkIn.new(model, model.alwaysOnDiscreteSchedule)
      wi.setName(obj['name'])
      wi.setRatedCoilCoolingCapacity(obj['RatedCoolingCapacity'].to_f)  if obj['RatedCoolingCapacity']
      wi.setOperatingTemperature(obj['OperatingTemperature'].to_f)       if obj['OperatingTemperature']
      wi.setRatedCoolingCoilFanPower(obj['CoolingFanPower'].to_f)        if obj['CoolingFanPower']
      wi.setRatedCirculationFanPower(0.0)
      wi.setRatedTotalLightingPower(obj['LightingPower'].to_f)           if obj['LightingPower']
      wi.setLightingSchedule(model.alwaysOnDiscreteSchedule)
      wi.setDefrostType('Electric') if obj['DefrostType'] && obj['DefrostType'].to_s.downcase.include?('electric')
      wi.setInsulatedFloorSurfaceArea(10.0)
      wi.setInsulatedFloorUValue(0.207)
      # Zone boundary — flat setters in OS 3.11
      wi.setZoneBoundaryThermalZone(zone)
      wi.setZoneBoundaryTotalInsulatedSurfaceAreaFacingZone(zone, 20.0)
      wi.setZoneBoundaryInsulatedSurfaceUValueFacingZone(zone, 0.235)
      wi.setZoneBoundaryAreaofStockingDoorsFacingZone(zone, obj['StockingDoorAreaFacingZone'].to_f) if obj['StockingDoorAreaFacingZone']
      wi.setZoneBoundaryHeightofStockingDoorsFacingZone(zone, 2.0)
      wi.setZoneBoundaryStockingDoorUValueFacingZone(zone, obj['StockingDoorUValue'].to_f) if obj['StockingDoorUValue']
      wi.setZoneBoundaryStockingDoorOpeningScheduleFacingZone(zone, model.alwaysOnDiscreteSchedule)
      walkin_count += 1
    end

    runner.registerFinalCondition("Applied advanced supermarket refrigeration: #{mt_rack_count} MT racks, #{lt_rack_count} LT racks, #{case_count} display cases, #{walkin_count} walk-ins.")
    true
# --- end user logic ---
    return true
  end
end

ApplySupermarketRefrigeration.new.registerWithApplication
