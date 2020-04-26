------------------------------------------------------------------------------
-- Forge Core
-- Author: Sledmine
-- Version: 1.0
-- Core functionality for Forge
------------------------------------------------------------------------------

local core = {}

-- Send a request to the server throug rcon
---@param data table
---@param playerIndex number
---@return boolean success
---@return string request
function core.sendRequest(data, playerIndex)
    cprint('Request data: ')
    cprint(inspect(data))
    cprint('-> [ Sending request ]')
    local requestType = constants.requestTypes[data.requestType]
    if (requestType) then
        cprint('Type: ' .. requestType, 'category')
        local compressionFormat = constants.compressionFormats[requestType]

        if (not compressionFormat) then
            cprint('There is no format compression for this request!!!!', 'error')
            return false
        end

        cprint('Compression: ' .. inspect(compressionFormat))

        local requestObject = maethrillian.compressObject(data, compressionFormat, true)

        local requestOrder = constants.requestFormats[requestType]
        local request = maethrillian.convertObjectToRequest(requestObject, requestOrder)

        request = "rcon forge '" .. request .. "'"

        cprint('Request: ' .. request)
        if (server_type == 'local') then
            -- We need to mockup the server response in local mode
            local mockedResponse = string.gsub(string.gsub(request, "rcon forge '", ''), "'", '')
            cprint('Local Request: ' .. mockedResponse)
            onRcon(mockedResponse)
            return true, mockedResponse
        elseif (server_type == 'dedicated') then
            -- Player is connected to a server
            cprint('Dedicated Request: ' .. request)
            execute_script(request)
            return true, request
        elseif (server_type == 'sapp') then
            local fixedResponse = string.gsub(request, "rcon forge '", '')
            cprint('Server Request: ' .. fixedResponse)

            -- We want to broadcast to every player in the server
            if (not playerIndex) then
                for i = 1, 16 do
                    if (player_present(i)) then
                        rprint(i, fixedResponse)
                    end
                end
            else
                -- We are looking to send data to a specific player
                rprint(playerIndex, fixedResponse)
            end
            return true, fixedResponse
        end
    end
    cprint('Error at trying to send request!!!!', 'error')
    return false
end

-- Create a request for an object action
---@param composedObject number
---@param requestType string
function core.createRequest(composedObject, requestType)
    local objectData = {}
    if (composedObject) then
        objectData.requestType = requestType
        if (requestType == constants.requestTypes.SPAWN_OBJECT) then
            objectData.tagId = composedObject.object.tagId
            if (server_type == 'sapp') then
                objectData.remoteId = composedObject.remoteId
            end
        elseif (requestType == constants.requestTypes.UPDATE_OBJECT) then
            composedObject.object = blam.object(get_object(composedObject.objectId))
            if (server_type ~= 'sapp') then
                objectData.objectId = composedObject.remoteId
            else
                objectData.objectId = composedObject.objectId
            end
        elseif (requestType == constants.requestTypes.DELETE_OBJECT) then
            if (server_type ~= 'sapp') then
                objectData.objectId = composedObject.remoteId
            else
                objectData.objectId = composedObject.objectId
            end
            return objectData
        elseif (requestType == constants.requestTypes.LOAD_MAP_SCREEN) then
            objectData.objectCount = composedObject.objectCount
            return objectData
        end
        objectData.x = composedObject.object.x
        objectData.y = composedObject.object.y
        objectData.z = composedObject.object.z
        objectData.yaw = composedObject.yaw
        objectData.pitch = composedObject.pitch
        objectData.roll = composedObject.roll
        return objectData
    end
    return nil
end

function core.loadForgeMap(mapName)
    local fmapContent = glue.readfile(forgeMapsFolder .. '\\' .. mapName .. '.fmap', 't')
    if (fmapContent) then
        cprint('Loading forge map...')
        local forgeMap = json.decode(fmapContent)
        if (forgeMap and forgeMap.objects and #forgeMap.objects > 0) then
            core.resetSpawnPoints()
            -- TO DO: Create flush system or features to load objects on map load
            --flushForge()
            for objectIndex, composedObject in pairs(forgeMap.objects) do
                composedObject.tagId = get_tag_id('scen', composedObject.tagPath)
                if (composedObject.tagId) then
                    composedObject.tagPath = nil
                    eventsStore:dispatch(
                        {type = constants.actionTypes.SPAWN_OBJECT, payload = {requestObject = composedObject}}
                    )
                else
                    cprint("WARNING!! Object with path '" .. mapName .. "' can't be spawn...", 'warning')
                end
            end
            cprint("Succesfully loaded '" .. mapName .. "' fmap!")
        else
            cprint("ERROR!! At decoding data from '" .. mapName .. "' forge map...", 'error')
        end
    else
        cprint("ERROR!! At trying to load '" .. mapName .. "' as a forge map...", 'error')
    end
end

function core.saveForgeMap(mapName)
    cprint('Saving forge map...')

    -- List used to store data of every object in the forge map
    local forgeMap = {
        name = mapName,
        author = '',
        description = '',
        version = '',
        objects = {}
    }

    -- Get the state of the forge objects
    local objectsState = eventsStore:getState().forgeObjects

    -- Iterate through all the forge objects
    for objectId, composedObject in pairs(objectsState) do
        -- Get scenery tag path to keep compatibility between versions
        local sceneryPath = get_tag_path(composedObject.object.tagId)
        cprint(sceneryPath)

        -- Create a copy of the composed object in the store to avoid replacing useful values
        local fmapComposedObject = {}
        for k, v in pairs(composedObject) do
            fmapComposedObject[k] = v
        end

        -- Remove all the unimportant data
        fmapComposedObject.object = nil
        fmapComposedObject.objectId = nil
        fmapComposedObject.remoteId = nil

        -- Add tag path property
        fmapComposedObject.tagPath = sceneryPath

        -- Add forge object to list
        glue.append(forgeMap.objects, fmapComposedObject)
    end

    -- Encode map info as JSON
    local fmapContent = json.encode(forgeMap)

    -- Update map name
    mapName = string.gsub(mapName, ' ', '_')

    local forgeMapFile = glue.writefile(forgeMapsFolder .. '\\' .. mapName .. '.fmap', fmapContent, 't')

    -- Check if file was created
    if (forgeMapFile) then
        cprint("Forge map '" .. mapName .. "' has been succesfully saved!", 'success')

        -- Reload forge maps list
        loadForgeMapsList()
    else
        cprint("ERROR!! At saving '" .. mapName .. "' as a forge map...", 'error')
    end
end

function core.resetSpawnPoints()
    local scenarioAddress
    if (server_type == 'sapp') then
        scenarioAddress = get_tag('scnr', constants.scenarioPath)
    else
        scenarioAddress = get_tag(0)
    end
    local scenario = blam.scenario(scenarioAddress)

    local mapSpawnCount = scenario.spawnLocationCount
    local vehicleLocationCount = scenario.vehicleLocationCount

    cprint('Found ' .. mapSpawnCount .. ' stock player starting points!')
    cprint('Found ' .. vehicleLocationCount .. ' stock vehicle location points!')
    local mapSpawnPoints = scenario.spawnLocationList
    -- Reset any spawn point, except the first one
    for i = 1, mapSpawnCount do
        -- Disable them by setting type to 0
        mapSpawnPoints[i].type = 0
    end
    local vehicleLocationList = scenario.vehicleLocationList
    for i = 2, vehicleLocationCount do
        vehicleLocationList[i].type = 65535
        execute_script('object_destroy v' .. vehicleLocationList[i].nameIndex)
    end
    blam.scenario(get_tag(0), {spawnLocationList = mapSpawnPoints, vehicleLocationList = vehicleLocationList})
end

return core