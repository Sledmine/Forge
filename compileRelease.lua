------------------------------------------------------------------------------
-- Forge Island Project Compiler
-- Sledmine
-- Script utility to compile the entire Forge Island project
------------------------------------------------------------------------------
-- Import constants
local forgeVersion = require "modules.forge.version"
local forgeBuild = arg[1]

local projectDataPath =
    [[D:\Program Files (x86)\Microsoft Games\Halo Custom Edition\projects\ForgeIsland\data\]]
local projectPath =
    [[D:\Program Files (x86)\Microsoft Games\Halo Custom Edition\projects\ForgeIsland\]]

if (forgeBuild) then
    forgeVersion = forgeVersion .. "+harvest"
    if (forgeBuild:find("dev")) then
        forgeVersion = forgeVersion .. ".dev"
    end
else
    print("Please specify a build name!")
    os.exit(1)
end

-- Generate bitmap version from code

local versionBitmapCmd =
    [[cd "%s[shm]\halo_4\ui\hud\bitmaps" & convert version_number_template.png +compress -fill "#aaaaaa" -size 512x128 -font "conduit_itc_medium.otf" -pointsize 98 -gravity center -draw "text 0,0 '%s'" version_number.tif]]

print("Generating bitmap version from Forge code...")
local result = os.execute(versionBitmapCmd:format(projectDataPath, forgeVersion:upper()))
if (result) then
    print("Done!")
else
    os.exit(1)
    print("Error, error occurred while generating bitmap version from Forge code.")
end

-- Compile bitmap version

local versionBitmapCompileCmd =
    [[cd "%s" & harvest bitmap "[shm]\halo_4\ui\hud\bitmaps\version_number"]]

print("Compiling bitmap version...")
local result = os.execute(versionBitmapCompileCmd:format(projectPath))
if (result) then
    print("Done!")
else
    os.exit(1)
    print("Error, an error occurred while compiling bitmap version.")
end

if (forgeBuild == "forge_island") then
    -- Replace forge island scenario with dev scenario
    local copyScenarioCmd =
        [[cd "%s\tags\[shm]\halo_4\maps\forge_island" && rm forge_island.scenario && cp forge_island_dev.scenario forge_island.scenario]]
    print("Replacing scenario...")
    local result = os.execute(copyScenarioCmd:format(projectPath))
    if (result) then
        print("Done!")
    else
        os.exit(1)
        print("Error, an error occurred while replacing map scenario.")
    end
end

-- Compile map
local compileMapCmd =
    [[cd "%s" & harvest build-cache-file "[shm]\halo_4\maps\forge_island\%s"]]

-- forge_island_dev
-- forge_island

print("Compiling map...")
local result = os.execute(compileMapCmd:format(projectPath, forgeBuild))
if (result) then
    print("Done!")
else
    os.exit(1)
    print("Error, an error occurred while compiling map.")
end
