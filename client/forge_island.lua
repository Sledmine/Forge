------------------------------------------------------------------------------
-- Forge Island Client Script
-- Sledmine
-- Client side script for Forge Island
------------------------------------------------------------------------------
-- Constants
clua_version = 2.042

-- Script name must be the base script name, without variants or extensions
scriptName = script_name:gsub(".lua", ""):gsub("_dev", ""):gsub("_beta", "")
-- Map name should be the base project name, without build env variants
absoluteMapName = map:gsub("_dev", ""):gsub("_beta", "")
defaultConfigurationPath = "config"
defaultMapsPath = "fmaps"

-- Lua libraries
local inspect = require "inspect"
local redux = require "lua-redux"
local glue = require "glue"
local ini = require "lua-ini"

-- Halo Custom Edition libraries
blam = require "blam"
-- Bind legacy Chimera printing to lua-blam printing
console_out = blam.consoleOutput
-- Create global reference to tagClasses
objectClasses = blam.objectClasses
tagClasses = blam.tagClasses
cameraTypes = blam.cameraTypes

-- Forge modules
local interface = require "forge.interface"
local features = require "forge.features"
local commands = require "forge.commands"
local core = require "forge.core"

-- Reducers importation
local playerReducer = require "forge.reducers.playerReducer"
local eventsReducer = require "forge.reducers.eventsReducer"
local forgeReducer = require "forge.reducers.forgeReducer"
local votingReducer = require "forge.reducers.votingReducer"

-- Reflectors importation
local forgeReflector = require "forge.reflectors.forgeReflector"
local votingReflector = require "forge.reflectors.votingReflector"

-- Forge default configuration
configuration = {}

configuration.forge = {
    debugMode = false,
    autoSave = false,
    autoSaveTime = 15000,
    snapMode = false,
    objectsCastShadow = false
}

-- Load forge configuration at script load time
core.loadForgeConfiguration()

-- Internal functions and variables
-- Buffer to store all the debug printing
debugBuffer = ""
-- Tick counter until next text draw refresh
textRefreshCount = 0
-- Object used to store mouse input across pre frame update
mouse = {}
local currentPermutation = 0
loadingFrame = 0

--- Function to send debug messages to console output
---@param message string
---@param color string
function dprint(message, color)
    if (configuration.forge.debugMode) then
        local message = message
        if (type(message) ~= "string") then
            message = inspect(message)
        end
        debugBuffer = (debugBuffer or "") .. message .. "\n"
        if (color == "category") then
            console_out(message, 0.31, 0.631, 0.976)
        elseif (color == "warning") then
            console_out(message, blam.consoleColors.warning)
        elseif (color == "error") then
            console_out(message, blam.consoleColors.error)
        elseif (color == "success") then
            console_out(message, blam.consoleColors.success)
        else
            console_out(message)
        end
    end
end

--- Function to automatically save a current Forge map
function autoSaveForgeMap()
    if (configuration.forge.autoSave and core.isPlayerMonitor()) then
        ---@type forgeState
        local forgeState = forgeStore:getState()
        local currentMapName = forgeState.currentMap.name
        if (currentMapName and currentMapName ~= "Unsaved") then
            core.saveForgeMap()
        end
    end
end

function OnMapLoad()
    -- Dinamically load constants for the current Forge map
    constants = require "forge.constants"

    -- Like Redux we have some kind of store baby!! the rest is pure magic..
    playerStore = redux.createStore(playerReducer)
    forgeStore = redux.createStore(forgeReducer) -- Isolated store for all the Forge 'app' data
    eventsStore = redux.createStore(eventsReducer) -- Unique store for all the Forge Objects
    votingStore = redux.createStore(votingReducer) -- Storage for all the state of map voting

    local forgeState = forgeStore:getState()

    -- TODO Migrate this into a feature or something
    local sceneriesTagCollection = blam.tagCollection(
                                       constants.tagCollections.forgeObjectsTagId)
    local forgeObjectsList = core.getForgeObjects(sceneriesTagCollection)
    -- Iterate over all the sceneries available in the sceneries tag collection
    for _, tagId in pairs(forgeObjectsList) do
        local tempTag = blam.getTag(tagId)
        if (tempTag and tempTag.path) then
            local sceneryPath = tempTag.path
            local sceneriesSplit = glue.string.split(sceneryPath, "\\")
            local sceneryFolderIndex
            for folderNameIndex, folderName in pairs(sceneriesSplit) do
                if (folderName == "scenery") then
                    sceneryFolderIndex = folderNameIndex + 1
                    break
                end
            end
            local fixedSplittedPath = {}
            for l = sceneryFolderIndex, #sceneriesSplit do
                fixedSplittedPath[#fixedSplittedPath + 1] = sceneriesSplit[l]
            end
            sceneriesSplit = fixedSplittedPath
            local sceneriesSplitLast = sceneriesSplit[#sceneriesSplit]

            forgeState.forgeMenu.objectsDatabase[sceneriesSplitLast] = sceneryPath
            -- Set first level as the root of available current objects
            -- Make a tree iteration to append sceneries
            local treePosition = forgeState.forgeMenu.objectsList.root
            for currentLevel, categoryLevel in pairs(sceneriesSplit) do
                -- TODO This is horrible, remove this "sort" implementation
                if (categoryLevel:sub(1, 1) == "_") then
                    categoryLevel = glue.string.fromhex(tostring((0x2))) ..
                                        categoryLevel:sub(2, -1)
                end
                if (not treePosition[categoryLevel]) then
                    treePosition[categoryLevel] = {}
                end
                treePosition = treePosition[categoryLevel]
            end
        end
    end

    -- Set current menu elements to objects list
    forgeState.forgeMenu.elementsList = glue.deepcopy(forgeState.forgeMenu.objectsList)

    -- Subscribed function to refresh forge state into the game!
    forgeStore:subscribe(forgeReflector)

    -- Dispatch forge objects list update
    forgeStore:dispatch({
        type = "UPDATE_FORGE_ELEMENTS_LIST",
        payload = {forgeMenu = forgeState.forgeMenu}
    })

    votingStore:subscribe(votingReflector)
    -- Dispatch forge objects list update
    votingStore:dispatch({type = "FLUSH_MAP_VOTES"})

    local isForgeMap = core.isForgeMap(map)
    if (isForgeMap) then
        core.loadForgeConfiguration()
        core.loadForgeMaps()

        -- Start autosave timer
        if (not autoSaveTimer and server_type == "local") then
            local autoSaveTime = configuration.forge.autoSaveTime
            autoSaveTimer = set_timer(autoSaveTime, "autoSaveForgeMap")
        end

        set_callback("tick", "OnTick")
        set_callback("preframe", "OnPreFrame")
        set_callback("rcon message", "OnRcon")
        set_callback("command", "OnCommand")

    else
        error("Error, This is not a compatible Forge CE map!!!")
    end
end

function OnPreFrame()
    local isPlayerOnMenu = read_byte(blam.addressList.gameOnMenus) == 0
    if (drawTextBuffer and not isPlayerOnMenu) then
        draw_text(table.unpack(drawTextBuffer))
    end
    -- Menu, UI Handling
    if (isPlayerOnMenu) then
        ---@type playerState
        local playerState = playerStore:getState()

        -- Maps Menu
        local mouse = features.getMouseInput()
        local pressedButton = interface.triggers("maps_menu", 11)
        if (mouse.scroll > 0) then
            pressedButton = 10
        elseif (mouse.scroll < 0) then
            pressedButton = 9
        end
        if (pressedButton) then
            dprint(" -> [ Maps Menu ]")
            if (pressedButton == 9) then
                -- Dispatch an event to increment current page
                forgeStore:dispatch({type = "DECREMENT_MAPS_MENU_PAGE"})
            elseif (pressedButton == 10) then
                -- Dispatch an event to decrement current page
                forgeStore:dispatch({type = "INCREMENT_MAPS_MENU_PAGE"})
            elseif (pressedButton == 11) then
                core.saveForgeMap()
            else
                local elementsList = blam.unicodeStringList(
                                         constants.unicodeStrings.mapsListTagId)
                local mapName = elementsList.stringList[pressedButton]:gsub(" ", "_")
                core.loadForgeMap(mapName)
            end
            dprint("Button " .. pressedButton .. " was pressed!", "category")
        end

        -- Forge Objects Menu
        mouse = features.getMouseInput()
        pressedButton = interface.triggers("forge_menu", 9)
        if (mouse.scroll > 0) then
            pressedButton = 8
        elseif (mouse.scroll < 0) then
            pressedButton = 7
        end
        if (pressedButton) then
            dprint(" -> [ Forge Menu ]")
            local forgeState = forgeStore:getState()
            if (pressedButton == 9) then
                if (forgeState.forgeMenu.desiredElement ~= "root") then
                    forgeStore:dispatch({type = "UPWARD_NAV_FORGE_MENU"})
                else
                    dprint("Closing Forge menu...")
                    interface.close(constants.uiWidgetDefinitions.forgeMenu)
                end
            elseif (pressedButton == 8) then
                forgeStore:dispatch({type = "INCREMENT_FORGE_MENU_PAGE"})
            elseif (pressedButton == 7) then
                forgeStore:dispatch({type = "DECREMENT_FORGE_MENU_PAGE"})
            else
                if (playerState.attachedObjectId) then
                    local elementsList = blam.unicodeStringList(
                                             constants.unicodeStrings
                                                 .forgeMenuElementsTagId)
                    local selectedElement = elementsList.stringList[pressedButton]
                    if (selectedElement) then
                        local elementsFunctions = features.getObjectMenuFunctions()
                        local buttonFunction = elementsFunctions[selectedElement]
                        if (buttonFunction) then
                            buttonFunction()
                        else
                            forgeStore:dispatch(
                                {
                                    type = "DOWNWARD_NAV_FORGE_MENU",
                                    payload = {desiredElement = selectedElement}
                                })
                        end
                    end
                else
                    local elementsList = blam.unicodeStringList(
                                             constants.unicodeStrings
                                                 .forgeMenuElementsTagId)
                    local selectedSceneryName = elementsList.stringList[pressedButton]
                    local sceneryPath =
                        forgeState.forgeMenu.objectsDatabase[selectedSceneryName]
                    if (sceneryPath) then
                        playerStore:dispatch({
                            type = "CREATE_AND_ATTACH_OBJECT",
                            payload = {path = sceneryPath}
                        })
                        interface.close(constants.uiWidgetDefinitions.forgeMenu)
                    else
                        forgeStore:dispatch({
                            type = "DOWNWARD_NAV_FORGE_MENU",
                            payload = {desiredElement = selectedSceneryName}
                        })
                    end
                end
            end
            dprint(" -> [ Forge Menu ]")
            dprint("Button " .. pressedButton .. " was pressed!", "category")

        end

        pressedButton = interface.triggers("map_vote_menu", 5)
        if (pressedButton) then
            local voteMapRequest = {
                requestType = constants.requests.sendMapVote.requestType,
                mapVoted = pressedButton
            }
            core.sendRequest(core.createRequest(voteMapRequest))
            dprint("Vote Map menu:")
            dprint("Button " .. pressedButton .. " was pressed!", "category")
        end
    else
        ---@type playerState
        local playerState = playerStore:getState()

        if (core.isPlayerMonitor() and playerState.attachedObjectId) then
            local mouse = features.getMouseInput()
            if (mouse.scroll > 0) then
                playerStore:dispatch({
                    type = "STEP_ROTATION_DEGREE",
                    payload = {substraction = true, multiplier = mouse.scroll}
                })
                playerStore:dispatch({type = "ROTATE_OBJECT"})
                features.printHUD(playerState.currentAngle:upper() .. ": " ..
                                      playerState[playerState.currentAngle])
            elseif (mouse.scroll < 0) then
                playerStore:dispatch({
                    type = "STEP_ROTATION_DEGREE",
                    payload = {substraction = false, multiplier = mouse.scroll}
                })
                playerStore:dispatch({type = "ROTATE_OBJECT"})
                features.printHUD(playerState.currentAngle:upper() .. ": " ..
                                      playerState[playerState.currentAngle])
            end
        end
    end
end

-- Where the magick happens, tiling!
function OnTick()
    local player = blam.biped(get_dynamic_player())

    ---@type playerState
    local playerState = playerStore:getState()
    if (player) then
        local oldPosition = playerState.position
        if (oldPosition) then
            player.x = oldPosition.x
            player.y = oldPosition.y
            player.z = oldPosition.z + 0.1
            playerStore:dispatch({type = "RESET_POSITION"})
        end
        if (player.isFrozen) then
            player.isFrozen = false
        end
        if (core.isPlayerMonitor()) then
            local controlsStrings = blam.unicodeStringList(
                                        constants.unicodeStrings.forgeControlsTagId)
            if (controlsStrings) then
                local newStrings = controlsStrings.stringList
                -- E key
                newStrings[1] = "Change rotation angle"
                -- Q key
                newStrings[2] = "Open Forge objects menu"
                -- F key
                newStrings[3] = "Swap Push N Pull mode"
                -- Control key
                newStrings[4] = "Get back into spartan mode"
                controlsStrings.stringList = newStrings
            end
            -- Provide better movement to monitors
            if (not player.ignoreCollision) then
                player.ignoreCollision = true
            end

            -- Check if monitor has an object attached
            local playerAttachedObjectId = playerState.attachedObjectId
            if (playerAttachedObjectId) then
                -- Calculate player point of view
                playerStore:dispatch({type = "UPDATE_OFFSETS"})
                -- Change rotation angle
                if (player.flashlightKey) then
                    features.openForgeObjectPropertiesMenu()
                elseif (player.actionKey) then
                    playerStore:dispatch({type = "CHANGE_ROTATION_ANGLE"})
                    features.printHUD("Rotating in " .. playerState.currentAngle)
                elseif (player.weaponPTH and player.jumpHold) then
                    local forgeObjects = eventsStore:getState().forgeObjects
                    local forgeObject = forgeObjects[playerAttachedObjectId]
                    if (forgeObject) then
                        -- Update object position
                        local object = blam.object(get_object(playerAttachedObjectId))
                        object.x = forgeObject.x
                        object.y = forgeObject.y
                        object.z = forgeObject.z
                        core.rotateObject(playerAttachedObjectId, forgeObject.yaw,
                                          forgeObject.pitch, forgeObject.roll)
                        playerStore:dispatch({
                            type = "DETACH_OBJECT",
                            payload = {undo = true}
                        })
                        return true
                    end
                elseif (player.meleeKey) then
                    playerStore:dispatch({
                        type = "SET_LOCK_DISTANCE",
                        payload = {lockDistance = not playerState.lockDistance}
                    })
                    features.printHUD("Distance from object is " ..
                                          tostring(glue.round(playerState.distance)) ..
                                          " units.")
                    if (playerState.lockDistance) then
                        features.printHUD("Push n pull.")
                    else
                        features.printHUD("Closer or further.")
                    end
                elseif (player.jumpHold) then
                    playerStore:dispatch({type = "DESTROY_OBJECT"})
                elseif (player.weaponSTH) then
                    local object = blam.object(get_object(playerAttachedObjectId))
                    if (not core.isObjectOutOfBounds(object)) then
                        playerStore:dispatch({type = "DETACH_OBJECT"})
                    end
                end

                if (not playerState.lockDistance) then
                    playerStore:dispatch({type = "UPDATE_DISTANCE"})
                    playerStore:dispatch({type = "UPDATE_OFFSETS"})
                end

                -- Update object position
                local object = blam.object(get_object(playerAttachedObjectId))
                if (object) then
                    object.x = playerState.xOffset
                    object.y = playerState.yOffset
                    object.z = playerState.zOffset
                end

                -- Unhighlight objects
                features.unhighlightAll()

                -- Update crosshair
                if (core.isObjectOutOfBounds(object)) then
                    features.setCrosshairState(4)
                else
                    features.setCrosshairState(3)
                end

            else

                -- Set crosshair to not selected state
                features.setCrosshairState(1)

                -- Unhide spawning related Forge objects
                features.hideReflectionObjects(false)
                features.unhighlightAll()

                local objectIndex, forgeObject, projectile =
                    core.getForgeObjectFromPlayerAim()
                -- Player is taking the object
                if (objectIndex) then
                    -- Hightlight the object that the player is looking at
                    features.highlightObject(objectIndex, 1)
                    features.setCrosshairState(2)
                    -- Get and parse object name
                    local tagId = blam.object(get_object(objectIndex)).tagId
                    local tagPath = blam.getTag(tagId).path
                    local objectPath = glue.string.split(tagPath, "\\")
                    local objectName = objectPath[#objectPath - 1]
                    local objectCategory = objectPath[#objectPath - 2]

                    if (objectCategory:sub(1, 1) == "_") then
                        objectCategory = objectCategory:sub(2, -1)
                    end

                    objectName = objectName:gsub("^%l", string.upper)
                    objectCategory = objectCategory:gsub("^%l", string.upper)

                    features.printHUD("NAME:  " .. objectName,
                                      "CATEGORY:  " .. objectCategory, 25)

                    if (player.weaponPTH and not player.jumpHold) then
                        playerStore:dispatch({
                            type = "ATTACH_OBJECT",
                            payload = {
                                objectId = objectIndex,
                                attach = {
                                    x = 0, -- projectile.x,
                                    y = 0, -- projectile.y,
                                    z = 0 -- projectile.z
                                },
                                fromPerspective = true
                            }
                        })
                        local object = blam.object(get_object(objectIndex))
                        dprint(object.x .. " " .. object.y .. " " .. object.z)
                        dprint(projectile.x .. " " .. projectile.y .. " " .. projectile.z)
                    elseif (player.actionKey) then
                        local tagId = blam.object(get_object(objectIndex)).tagId
                        local tagPath = blam.getTag(tagId).path
                        -- TODO Add color copy from object
                        playerStore:dispatch({
                            type = "CREATE_AND_ATTACH_OBJECT",
                            payload = {path = tagPath}
                        })
                        playerStore:dispatch({
                            type = "SET_ROTATION_DEGREES",
                            payload = {
                                yaw = forgeObject.yaw,
                                pitch = forgeObject.pitch,
                                roll = forgeObject.roll
                            }
                        })
                        playerStore:dispatch({type = "ROTATE_OBJECT"})
                    end
                end
                -- Open Forge menu by pressing "Q"
                if (player.flashlightKey) then
                    dprint("Opening Forge menu...")
                    local forgeState = forgeStore:getState()
                    forgeState.forgeMenu.elementsList =
                        glue.deepcopy(forgeState.forgeMenu.objectsList)
                    forgeStore:dispatch({
                        type = "UPDATE_FORGE_ELEMENTS_LIST",
                        payload = {forgeMenu = forgeState.forgeMenu}
                    })
                    features.openMenu(constants.uiWidgetDefinitions.forgeMenu.path)
                elseif (player.crouchHold and server_type == "local") then
                    features.swapBiped()
                    playerStore:dispatch({type = "DETACH_OBJECT"})
                end
            end
        else
            --[[local projectile, projectileIndex = core.getPlayerAimingSword()
            if (projectile) then
                dprint(player.xVel .. " " .. player.yVel .. " " .. player.zVel)
                player.xVel = player.cameraX * 0.2
                player.yVel = player.cameraY * 0.2
                player.zVel = player.cameraZ * 0.06
            end]]
            local controlsStrings = blam.unicodeStringList(
                                        constants.unicodeStrings.forgeControlsTagId)
            if (controlsStrings) then
                local newStrings = controlsStrings.stringList
                -- E key
                newStrings[1] = "No Forge action"
                -- Q key
                newStrings[2] = "Get into monitor mode"
                -- F key
                newStrings[3] = "No Forge action"
                -- Control key
                newStrings[4] = "No Forge action"
                controlsStrings.stringList = newStrings
            end
            features.regenerateHealth()
            features.hudUpgrades()
            features.hideReflectionObjects(true)
            features.setCrosshairState(0)
            -- Convert into monitor
            if (player.flashlightKey and not player.crouchHold) then
                features.swapBiped()
            elseif (configuration.forge.debugMode and player.actionKey and
                player.crouchHold and server_type == "local") then
                local bipedTag = blam.getTag(constants.bipeds.spartanTagId)
                core.spawnObject(tagClasses.biped, bipedTag.path, player.x, player.y,
                                 player.z)
            elseif (configuration.forge.debugMode and player.flashlightKey and
                player.crouchHold and server_type == "local") then
                if (currentPermutation < 12) then
                    currentPermutation = currentPermutation + 1
                else
                    currentPermutation = 0
                end
                player.regionPermutation2 = currentPermutation
            end
        end
    end

    -- Attach respective hooks for menus
    interface.hook("maps_menu_hook", interface.stop,
                   constants.uiWidgetDefinitions.mapsList)
    interface.hook("forge_menu_hook", interface.stop,
                   constants.uiWidgetDefinitions.objectsList)
    interface.hook("forge_menu_close_hook", interface.stop,
                   constants.uiWidgetDefinitions.forgeMenu)
    interface.hook("loading_menu_close_hook", interface.stop,
                   constants.uiWidgetDefinitions.loadingMenu)

    -- Update tick count
    textRefreshCount = textRefreshCount + 1

    -- We need to draw new text, erase the older one
    if (textRefreshCount > 30) then
        textRefreshCount = 0
        drawTextBuffer = nil
    end
end

function OnRcon(message)
    local request = string.gsub(message, "'", "")
    local splitData = glue.string.split(request, constants.requestSeparator)
    local incomingRequest = splitData[1]
    local actionType
    local currentRequest
    for requestName, request in pairs(constants.requests) do
        if (incomingRequest and incomingRequest == request.requestType) then
            currentRequest = request
            actionType = request.actionType
        end
    end
    if (actionType) then
        return core.processRequest(actionType, request, currentRequest)
    end
    return true
end

function OnCommand(command)
    return commands(command)
end

function OnMapUnload()
    -- Flush all the forge objects
    core.flushForge()

    -- Save configuration
    write_file(defaultConfigurationPath .. "\\forge_island.ini", ini.encode(configuration))
end

if (server_type == "local") then
    OnMapLoad()
end
-- Prepare event callbacks
set_callback("map load", "OnMapLoad")
set_callback("unload", "OnMapUnload")
