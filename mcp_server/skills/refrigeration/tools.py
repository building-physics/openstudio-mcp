"""Refrigeration tools — MCP tool registration."""
from __future__ import annotations

from mcp_server.skills.refrigeration import operations


def register(mcp):
    @mcp.tool()
    def create_supermarket_refrigeration_system(
        template: str = "advanced",
        building_type: str = "SuperMarket",
    ) -> dict:
        """Create a supermarket refrigeration system and export to OpenStudio JSON.

        Args:
            template: System template - "old", "new", or "advanced"
            building_type: Building type - currently only "SuperMarket"

        Returns:
            Output file path and system summary
        """
        return operations.create_supermarket_refrigeration_system(
            template=template,
            building_type=building_type,
        )