"""Refrigeration operations — supermarket refrigeration system modeling."""
from __future__ import annotations

import sys
import os
from typing import Any


def create_supermarket_refrigeration_system(
    template: str = "advanced",
    building_type: str = "SuperMarket",
) -> dict[str, Any]:
    try:
        refrig_path = os.environ.get("REFRIGERATION_REPO_PATH", "/refrigeration")
        if refrig_path not in sys.path:
            sys.path.insert(0, refrig_path)

        db_path = os.path.join(refrig_path, "database/openstudio_refrigeration_system.db")

        from refrigeration.mode_selection import SuperMarketSystem
        from refrigeration.rack_assignment import assign_racks_to_cases_and_walkins
        from refrigeration.compressor import summarize_compressor_assignment, prepare_and_store_compressor_objects
        from refrigeration.condenser import prepare_and_store_condenser_objects
        from refrigeration.case_walkin_objects import prepare_and_store_case_and_walkin_objects
        from refrigeration.system_objects import prepare_and_store_system_and_casewalkin_lists
        from refrigeration.full_export import export_full_refrigeration_system_to_json

        # Step 1
        system = SuperMarketSystem(template, db_path)
        system.load_defaults()
        selected_case_units = system.cases
        selected_walkin_units = system.walkins
        selected_template = template
        case_zone = "MainSales"
        walkin_zone = "ActiveStorage"

        # Step 2
        mt_racks, lt_racks, case_data, walkin_data = assign_racks_to_cases_and_walkins(
            db_path, selected_case_units, selected_walkin_units
        )

        # Step 3
        result = prepare_and_store_case_and_walkin_objects(
            case_data, walkin_data, selected_case_units, selected_walkin_units, case_zone, walkin_zone
        )
        case_objects = result["case_objects"]
        walkin_objects = result["walkin_objects"]

        # Step 4
        mt_info, lt_info = summarize_compressor_assignment(mt_racks, lt_racks, selected_template)
        result = prepare_and_store_compressor_objects(mt_info, lt_info, selected_template, db_path)
        mt_compressors = result["mt_compressors"]
        lt_compressors = result["lt_compressors"]
        mt_power_curve = result["mt_power_curve"]
        mt_capacity_curve = result["mt_capacity_curve"]
        lt_power_curve = result["lt_power_curve"]
        lt_capacity_curve = result["lt_capacity_curve"]

        # Step 5
        result = prepare_and_store_condenser_objects(mt_info, lt_info, selected_template)
        mt_condensers = result["mt_condensers"]
        lt_condensers = result["lt_condensers"]
        mt_curves = result["mt_curves"]
        lt_curves = result["lt_curves"]

        # Step 6
        system_and_casewalkin_objects = prepare_and_store_system_and_casewalkin_lists(
            selected_case_units, selected_walkin_units, mt_racks, lt_racks, selected_template
        )

        # Step 7
        output_path = f"/runs/{building_type}_{selected_template}_refrigeration_system.json"
        export_full_refrigeration_system_to_json(
            mt_compressors=mt_compressors,
            lt_compressors=lt_compressors,
            mt_power_curve=mt_power_curve,
            mt_capacity_curve=mt_capacity_curve,
            lt_power_curve=lt_power_curve,
            lt_capacity_curve=lt_capacity_curve,
            mt_condensers=mt_condensers,
            lt_condensers=lt_condensers,
            mt_curves=mt_curves,
            lt_curves=lt_curves,
            case_objects=case_objects,
            walkin_objects=walkin_objects,
            system_and_casewalkin_objects=system_and_casewalkin_objects,
            case_zone_name=case_zone,
            walkin_zone_name=walkin_zone,
            output_path=output_path,
        )

        return {
            "ok": True,
            "output_path": output_path,
            "template": selected_template,
            "building_type": building_type,
            "mt_rack_count": len(mt_racks),
            "lt_rack_count": len(lt_racks),
            "case_count": len(case_objects),
            "walkin_count": len(walkin_objects),
        }

    except Exception as e:
        return {"ok": False, "error": f"Failed to create refrigeration system: {e}"}