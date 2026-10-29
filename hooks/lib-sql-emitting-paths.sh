#!/usr/bin/env bash
# One copy of "this diff changes the SQL a report emits, or the values it returns" -- sourced by
# octopus-staging-cache-update-reminder.sh (cache invalidation) and
# ama-deploy-release/scripts/release-preflight.sh (EXPLAIN shape sweep, SHARED-CHOKEPOINT-CHANGES.md).
# Two private copies of a path list drift; that is how a builder path ends up nudging one check
# and silently missing the other.
#
# Path history (kept with the pattern): SqlTemplates/DataDictionary/migrations from the start;
# Search.Shared Builders/Criteria 2026-09-27 (PROJ-15411 -- a builder change alters what a
# query returns); Services/Query/Executor/Formatters + Search.Domain result builders 2026-10-05
# (the cache stores the post-processed result); fieldtablemapper mappings (change the SQL from
# outside search).
SQL_EMITTING_PATHS='SqlTemplate|DataDictionary|Database/Migrations|Database\\Migrations|R__Add_Sql_Template_Data|HistoricalWamFieldBuilder|AgingCurveQueryBuilder|Search\.Shared[/\\](Builders|Criteria|Services|Query|Executor|Formatters)|Search\.Domain[/\\](Builders|Services)|FieldTableMapper\.(Domain|Lambda)[/\\]'

# sql_emitting_diff <repo> <base> <head> -> prints matching paths (max 5); also a Search.Shared /
# Search.Cache PackageReference change, which ships new SQL with no path match (resultsprocessor,
# cohortdata, manage, export-cohort consume the builders by NuGet -- PROJ-15801's hotfix).
# Test projects (*.Tests/, *.IntegrationTests/, ...) are skipped: nothing deployed reads them, and
# PROJ-15881's recorded sqltemplates-*.json fixtures matched SqlTemplate and nudged a QA
# cache update for a test-only push.
sql_emitting_diff() {
  local repo="$1" base="$2" head="$3"
  git -C "$repo" diff --name-only "$base" "$head" 2>/dev/null | grep -iP "$SQL_EMITTING_PATHS" \
    | grep -viP '\.\w*Tests[/\\]' | head -5
  git -C "$repo" diff "$base" "$head" -- '*.csproj' 2>/dev/null \
    | grep -qE '^[+-].*PackageReference.*Search\.(Shared|Cache)' && echo "(Search.Shared/Search.Cache package version changed)"
  return 0
}
