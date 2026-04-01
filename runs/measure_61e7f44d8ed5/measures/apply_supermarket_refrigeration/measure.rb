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

    runner.registerInitialCondition("Loading refrigeration system from: #{json_path_val} (#{objects.size} objects)")

    # --- Collect or create thermal zones ---
    zone_map = {}
    model.getThermalZones.each { |z| zone_map[z.name.to_s] = z }

    # Ensure required zones exist
    ['MainSales', 'ActiveStorage'].each do |zname|
      unless zone_map.key?(zname)
        z = OpenStudio::Model::ThermalZone.new(model)
        z.setName(zname)
        zone_map[zname] = z
        runner.registerInfo("Created thermal zone: #{zname}")
      end
    end

    # --- Build performance curves ---
    curve_map = {}
    objects.select { |o| o['type'] == 'OS:Curve:Bicubic' }.each do |obj|
      c = OpenStudio::Model::CurveBicubic.new(model)
      c.setName(obj['name'])
      c.setCoefficient1Constant(obj['Coefficient1Constant'].to_f)
      c.setCoefficient2x(obj['Coefficient2x'].to_f)
      c.setCoefficient3xPOW2(obj['Coefficient3x2'].to_f)
      c.setCoefficient4y(obj['Coefficient4y'].to_f)
      c.setCoefficient5yPOW2(obj['Coefficient5y2'].to_f)
      c.setCoefficient6xTIMESY(obj['Coefficient6xy'].to_f)
      c.setCoefficient7xPOW3(obj['Coefficient7x3'].to_f)
      c.setCoefficient8xPOW2TIMESY(obj['Coefficient8x2y'].to_f)
      c.setCoefficient9xTIMESYPOW2(obj['Coefficient9xy2'].to_f)
      c.setCoefficient10yPOW3(obj['Coefficient10y3'].to_f)
      c.setMinimumValueofx(obj['MinimumValueofx'].to_f)
      c.setMaximumValueofx(obj['MaximumValueofx'].to_f)
      c.setMinimumValueofy(obj['MinimumValueofy'].to_f)
      c.setMaximumValueofy(obj['MaximumValueofy'].to_f)
      curve_map[obj['name']] = c
    end

    objects.select { |o| o['type'] == 'OS:Curve:Linear' }.each do |obj|
      c = OpenStudio::Model::CurveLinear.new(model)
      c.setName(obj['name'])
      c.setCoefficient1Constant(obj['Coefficient1Constant'].to_f)
      c.setCoefficient2x(obj['Coefficient2x'].to_f)
      c.setMinimumValueofx(obj['MinimumValueofx'].to_f)
      c.setMaximumValueofx(obj['MaximumValueofx'].to_f)
      curve_map[obj['name']] = c
    end

    runner.registerInfo("Created #{curve_map.size} performance curves")

    # --- Build compressors ---
    compressor_map = {}
    objects.select { |o| o['type'] == 'OS:Refrigeration:Compressor' }.each do |obj|
      comp = OpenStudio::Model::RefrigerationCompressor.new(model)
      comp.setName(obj['name'])
      comp.setRatedReturnedGasTemperature(obj['SuctionTemperature'].to_f) if obj['SuctionTemperature']
      curve_name = obj['CompressorCurve']
      if curve_name && curve_map[curve_name]
        comp.setRefrigerationCompressorPowerCurve(curve_map[curve_name])
      end
      compressor_map[obj['name']] = comp
    end

    runner.registerInfo("Created #{compressor_map.size} compressors")

    # --- Group compressors by rack ---
    mt_racks = {}
    lt_racks = {}
    compressor_map.each do |name, comp|
      if name =~ /ADVANCED_(MT|LT)_Rack(\d+)_/
        type_str = $1
        rack_num = $2
        if type_str == 'MT'
          mt_racks[rack_num] ||= []
          mt_racks[rack_num] << comp
        else
          lt_racks[rack_num] ||= []
          lt_racks[rack_num] << comp
        end
      end
    end

    # --- Build condensers ---
    condenser_map = {}
    objects.select { |o| o['type'] == 'OS:Refrigeration:Condenser:AirCooled' }.each do |obj|
      cond = OpenStudio::Model::RefrigerationCondenserAirCooled.new(model)
      cond.setName(obj['name'])
      cond.setRatedEffectiveTotalHeatRejectionRate(obj['RatedEffectiveTotalHeatRejectionRate'].to_f) if obj['RatedEffectiveTotalHeatRejectionRate']
      cond.setRatedSubcoolingTemperatureDifference(obj['RatedSubcoolingTemperatureDifference'].to_f) if obj['RatedSubcoolingTemperatureDifference']
      cond.setMinimumCondensingTemperature(obj['MinimumCondensingTemperature'].to_f) if obj['MinimumCondensingTemperature']
      fan_curve_name = obj['FanPowerCurve']
      if fan_curve_name && curve_map[fan_curve_name]
        cond.setCondenserFanSpeedControlType('VariableSpeed')
      end
      condenser_map[obj['name']] = cond
    end

    runner.registerInfo("Created #{condenser_map.size} condensers")

    # --- Build MT compressor racks ---
    mt_rack_count = 0
    mt_racks.each do |rack_num, comps|
      rack_name = "MT_Rack#{rack_num}"
      cond_name = "MT_Rack#{rack_num}_Condenser"
      next unless condenser_map[cond_name]

      rack = OpenStudio::Model::RefrigerationSystem.new(model)
      rack.setName(rack_name)
      rack.setRefrigerationCondenser(condenser_map[cond_name])
      rack.setSumUASuctionPiping(0.0)
      comps.each { |c| rack.addCompressor(c) }
      mt_rack_count += 1
    end

    # --- Build LT compressor racks ---
    lt_rack_count = 0
    lt_racks.each do |rack_num, comps|
      rack_name = "LT_Rack#{rack_num}"
      cond_name = "LT_Rack#{rack_num}_Condenser"
      next unless condenser_map[cond_name]

      rack = OpenStudio::Model::RefrigerationSystem.new(model)
      rack.setName(rack_name)
      rack.setRefrigerationCondenser(condenser_map[cond_name])
      rack.setSumUASuctionPiping(0.0)
      comps.each { |c| rack.addCompressor(c) }
      lt_rack_count += 1
    end

    runner.registerInfo("Created #{mt_rack_count} MT racks and #{lt_rack_count} LT racks")

    # --- Build display cases ---
    case_count = 0
    objects.select { |o| o['type'] == 'OS:Refrigeration:Case' }.each do |obj|
      zone_name = obj['ZoneName'] || 'MainSales'
      zone = zone_map[zone_name]
      next unless zone

      rc = OpenStudio::Model::RefrigerationCase.new(model, model.alwaysOnDiscreteSchedule, zone)
      rc.setName(obj['name'])
      rc.setRatedTotalCoolingCapacityperUnitLength(obj['RatedTotalCoolingCapacity'].to_f / [obj['CaseLength'].to_f, 1.0].max) if obj['RatedTotalCoolingCapacity'] && obj['CaseLength']
      rc.setCaseLength(obj['CaseLength'].to_f) if obj['CaseLength']
      rc.setCaseOperatingTemperature(obj['OperatingTemperature'].to_f) if obj['OperatingTemperature']
      rc.setDesignEvaporatorTemperatureorBrineInletTemperature(obj['EvaporatorTemperature'].to_f) if obj['EvaporatorTemperature']
      rc.setRatedLatentHeatRatio(obj['RatedLatentHeatRatio'].to_f) if obj['RatedLatentHeatRatio']
      rc.setRatedRuntimeFraction(obj['RatedRuntimeFraction'].to_f) if obj['RatedRuntimeFraction']
      rc.setInstalledCaseLightingPowerperUnitLength(obj['LightingPowerPerUnitLength'].to_f) if obj['LightingPowerPerUnitLength']
      rc.setCaseFanPowerperUnitLength(obj['FanPowerPerUnitLength'].to_f) if obj['FanPowerPerUnitLength']
      rc.setDesignEvaporatorTemperatureorBrineInletTemperature(obj['EvaporatorTemperature'].to_f) if obj['EvaporatorTemperature']
      case_count += 1
    end

    runner.registerInfo("Created #{case_count} display cases")

    # --- Build walk-ins ---
    walkin_count = 0
    objects.select { |o| o['type'] == 'OS:Refrigeration:WalkIn' }.each do |obj|
      zone_name = obj['ZoneName'] || 'ActiveStorage'
      zone = zone_map[zone_name]
      next unless zone

      wi = OpenStudio::Model::RefrigerationWalkIn.new(model, model.alwaysOnDiscreteSchedule)
      wi.setName(obj['name'])
      wi.setRatedCoolingCapacity(obj['RatedCoolingCapacity'].to_f) if obj['RatedCoolingCapacity']
      wi.setOperatingTemperature(obj['OperatingTemperature'].to_f) if obj['OperatingTemperature']
      wi.setRatedCoolingSourceTemperature(obj['RatedCoolingSourceTemperature'].to_f) if obj['RatedCoolingSourceTemperature'] && !obj['RatedCoolingSourceTemperature'].nil?
      wi.setRatedTotalHeatingPower(obj['RatedTotalHeatingPower'].to_f) if obj['RatedTotalHeatingPower'] && !obj['RatedTotalHeatingPower'].nil?
      wi.setHeatingPowerSchedule(model.alwaysOnDiscreteSchedule)
      wi.setRatedCoolingCoilFanPower(obj['CoolingFanPower'].to_f) if obj['CoolingFanPower']
      wi.setRatedCirculationFanPower(0.0)
      wi.setRatedTotalLightingPower(obj['LightingPower'].to_f) if obj['LightingPower']
      wi.setLightingSchedule(model.alwaysOnDiscreteSchedule)
      wi.setDefrostType('Electric') if obj['DefrostType']&.downcase&.include?('electric')
      wi.setInsulatedFloorSurfaceArea(10.0)
      wi.setInsulatedFloorUValue(0.207)

      # Add zone boundary
      boundary = OpenStudio::Model::RefrigerationWalkInZoneBoundary.new(model)
      boundary.setThermalZone(zone)
      boundary.setTotalInsulatedSurfaceAreaFacingZone(obj['TotalInsulatedSurfaceAreaFacingZone'].to_f) if obj['TotalInsulatedSurfaceAreaFacingZone'] && !obj['TotalInsulatedSurfaceAreaFacingZone'].nil?
      boundary.setTotalInsulatedSurfaceAreaFacingZone(20.0) if obj['TotalInsulatedSurfaceAreaFacingZone'].nil?
      boundary.setInsulatedSurfaceUValueFacingZone(obj['InsulatedSurfaceUValueFacingZone'].to_f) if obj['InsulatedSurfaceUValueFacingZone'] && !obj['InsulatedSurfaceUValueFacingZone'].nil?
      boundary.setInsulatedSurfaceUValueFacingZone(0.235) if obj['InsulatedSurfaceUValueFacingZone'].nil?
      boundary.setAreaofStockingDoorsFacingZone(obj['StockingDoorAreaFacingZone'].to_f) if obj['StockingDoorAreaFacingZone']
      boundary.setHeightofStockingDoorsFacingZone(2.0)
      boundary.setStockingDoorUValueFacingZone(obj['StockingDoorUValue'].to_f) if obj['StockingDoorUValue']
      boundary.setStockingDoorOpeningScheduleFacingZone(model.alwaysOnDiscreteSchedule)
      wi.addZoneBoundary(boundary)

      walkin_count += 1
    end

    runner.registerFinalCondition("Applied advanced supermarket refrigeration: #{mt_rack_count} MT racks, #{lt_rack_count} LT racks, #{case_count} cases, #{walkin_count} walk-ins.")
    true

    # --- end user logic ---
    return true
  end
end

ApplySupermarketRefrigeration.new.registerWithApplication
