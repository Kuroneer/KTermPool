--[[
    <KTermPool: A simple module for AwesomeWM 3.5 that maintains a pool of hidden clients spawned with provided commands>
    Copyright (C) <2015>  Jose Maria Perez Ramos>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Maria Perez Ramos <kuron33r gmail.com>
    Date: 2015.12.06
    Version: 1.0.0
--]]

--[[
    KTermPool is an AwesomeWM 3.5 module that will keep a stack of hidden
    (but started) clients, and will show one of them when it notices
    AwesomeWM spawning a command that would create one.
    This reduces the time between issuing the spawn command and having
    the client ready, which is pretty useful when having a lot of
    terminals with expensive loads or just a slow computer.
    (On my old laptop, time between urxvt spawn and manage events has
    been reduced from 1.45s to 5ms, just because it's already started).

    When KTermPool is provided with a command, it will spawn several
    hidden clients and then it will intercept calls to awful.util.spawn
    to show one of the hidden clients, after which the pool is filled
    again.

    The intent of this module is to be used with terminal spawning
    commands, but there's no problem when using it with other kind of
    window-creating commands, just be aware of:
      - When Awesome exits, remaining clients in the pool will be KILLED
      - The command stars executing even when its client is not shown
      - If the command exits before a client is shown, it will consume a
        slot in the pool and this slot wont be freed until its pid gets
        reused by the system (in fact, this will cause the client to be
        hidden, since KTermPool will misinterpret it as a command to be
        handled)
        This shouldn't be a problem with terminal or other GUI commands
        but if you are worried about it, you may want to enable the
        pool garbage collector, which fixes this problem with only a
        periodic task.

    USAGE:
        Just load it in your rc.lua like this:

            require("ktermpool").addCmd(terminal, 5)

        the API is simple:

            addCmd( cmd [, poolSize = 1 ])

                Registers a command to be intercepted and handled, it
                will spawn poolSize hidden commands.

            removeCmd( cmd )

                Unregisters a command, killing all hidden clients.

            enableGC()

                Enables garbage collection, it will check periodically
                if the pids that are marked as "spawned" are actually
                spawned, and remove them otherwise.
--]]


local awful = require("awful")
local client = require("client")
local timer = require("timer")
local debug = function() end


-------------------------------
-- Redefine awful.util.spawn
local _spawn = awful.util.spawn
local __spawn = _spawn -- In case GC is activated
local intercepted = setmetatable({}, {
    __index = function() return _spawn end,
})
awful.util.spawn = function(cmd, ...)
    -- if cmd is managed (there's an entru in intercepted[cmd]),
    -- it will be called, otherwise just call old spawn (_spawn)
    intercepted[cmd](cmd, ...)
end
-------------------------------


-------------------------------
-- Redefine awful.rules.apply to avoid applying to managed clients
-- they will be applied by the next manage fired by spawn()
local _apply = nil --prevoius apply
local interceptedAllCmd = {} -- Pid of windows to manage but yet to show up
local interceptedAllCmdSize = 0
local interceptApply = function(c)
    -- Check if client has a chance to be handled
    if c.pid and interceptedAllCmdSize > 0 then
        -- Check if client is to be handled
        local interceptedCmdTable = interceptedAllCmd[c.pid]
        if interceptedCmdTable and interceptedCmdTable.retValues[c.pid] then
            -- client is handled, do not apply rules
            interceptedCmdTable:enqueue(c)
            return
        end
    end

    _apply(c)
end

if awful.rules then
    _apply = awful.rules.apply
    awful.rules.apply = interceptApply
else
    _apply = awful.tag.withcurrent
end

client.connect_signal("manage", interceptApply)
client.disconnect_signal("manage", _apply)
-------------------------------


-------------------------------
-- Schedule cleanup
awesome.connect_signal("exit", function()
    for cmd, t in pairs(intercepted) do t:cleanup() end
end)
-------------------------------


-------------------------------
-- Module functions
local function removeCmd(cmd)
    if type(cmd) ~= "string" or not rawget(intercepted, cmd) then
        return false
    end

    return intercepted[cmd]:cleanup();
end

local function addCmd(cmd, maxPoolsize)
    if type(cmd) ~= "string" or rawget(intercepted, cmd) then
        return false
    end

    intercepted[cmd] = setmetatable({
        cmd = cmd,
        clients = {},
        retValues = {},
        poolsize = 0,
        nextPid = nil,
        maxPoolsize = maxPoolsize or 1,

        spawnTimer = timer and timer{timeout = 0},
        spawnTimerHandler = function(selfTimer)
            intercepted[cmd]:spawn()
            selfTimer:stop()
        end,
        spawn = function(self, useTimer) -- From __call and startup
            if useTimer and self.spawnTimer then
                self.spawnTimer:start()
            else
                debug("KTP: Spawn: Start", self.cmd)
                for i = self.poolsize, self.maxPoolsize - 1 do
                    local ret = {__spawn(self.cmd)} -- Usually the same as _spawn
                    local pid = unpack(ret)

                    self.poolsize = self.poolsize + 1
                    self.retValues[pid] = ret

                    interceptedAllCmdSize = interceptedAllCmdSize + 1
                    interceptedAllCmd[pid] = self

                    debug("KTP: Spawn: Spawned", self.cmd, pid)
                end
            end
        end,

        enqueue = function(self, client) -- From manage
            local clientPid = client.pid
            debug("KTP: Enqueue: Start", self.cmd, clientPid)
            self.clients[clientPid] = {
                client = client,
                self.retValues[clientPid],
                client.hidden,
                nextPid = self.nextPid
            }

            self.retValues[clientPid] = nil
            interceptedAllCmd[clientPid] = nil
            interceptedAllCmdSize = interceptedAllCmdSize - 1

            client.hidden = true
            client:tags({})

            self.nextPid = clientPid
        end,

        take = function(self) -- From __call
            debug("KTP: Take: Start", self.cmd, self.poolsize)
            while self.nextPid do
                local clientTable = self.clients[self.nextPid]
                self.clients[self.nextPid] = nil
                self.nextPid = clientTable.nextPid
                self.poolsize = self.poolsize - 1

                if pcall(function() return clientTable.client.window end) then
                    -- Check if client is really there (could have been killed)
                    return clientTable.client, unpack(clientTable)
                end
                debug("KTP: Take: Check next client")
            end
            debug("KTP: Take: No client found")
        end,

        cleanup = function(self)
            self.spawnTimer:disconnect_signal("timeout", self.spawnTimerHandler)

            for pid in pairs(self.retValues) do
                if interceptedAllCmd[pid] then
                    interceptedAllCmd[pid] = nil
                    interceptedAllCmdSize = interceptedAllCmdSize - 1
                end
            end
            for pid, clientTable in pairs(self.clients) do
                clientTable.client:kill()
            end

            intercepted[cmd] = nil
            return true
        end,
    }, {
        __call = function(t, ...) -- awesome.util.spawn calls this with handled cmd
            local cmd, sn = ...
            if cmd and not sn then
                -- Need a client for a handled command!
                local client, retVal, wasHidden = t:take()
                t:spawn(true) -- Schedule refill

                if client then
                    debug("KTP: Called SPAWN: Returned client", cmd, client.pid)
                    client.hidden = wasHidden
                    client:emit_signal("manage")
                    return unpack(retVal)
                else
                    debug("KTP: Called SPAWN: No clients left", cmd)
                    -- Unavailable:
                    --  - Killed
                    --  - Too many requested
                    return _spawn(cmd)
                end
            else
                debug("KTP: Called SPAWN: With SN :(", cmd)
                -- No startup notification support :(
                return _spawn(...)
            end
        end
    })

    -- Set timeout
    intercepted[cmd].spawnTimer:connect_signal("timeout", intercepted[cmd].spawnTimerHandler)

    -- Spawn trying to use a timer
    intercepted[cmd]:spawn(true)

    return true
end

local gcTimer = nil
local function enableGC(timeout)
    if gcTimer then return end

    debug("KTP: GC enabled")
    gcTimer = timer{timeout = timeout or 30}
    gcTimer:connect_signal("timeout", function(self)
        if interceptedAllCmdSize == 0 then
            self:stop()
            debug("KTP: GC Off")
            return
        end

        debug("KTP: GC In")
        local ps = io.popen("ps -e")
        local pids = {}
        if ps then
            for line in ps:lines() do
                local pid = tonumber(line:match("^(%d+) .*$"))
                if pid then
                    pids[pid] = pid
                end
            end
            ps:close()
        end

        for pid, interceptedCmdTable in pairs(interceptedAllCmd) do
            if not pids[pid] then
                -- Pid does not exist, remove from wherever
                interceptedCmdTable.retValues[pid] = nil
                interceptedCmdTable.poolsize = interceptedCmdTable.poolsize - 1
                interceptedAllCmd[pid] = nil
                interceptedAllCmdSize = interceptedAllCmdSize - 1
                debug("KTP: GC collected", cmd, pid)
            end
        end
    end)

    __spawn = function(...) -- redefine spawn function that fills the pool
        gcTimer:start()
        debug("KTP: GC On")
        return _spawn(...)
    end
end
-------------------------------


-- Return module
return {
    addCmd = addCmd,
    removeCmd = removeCmd,
    enableGC = enableGC,
    _spawn = _spawn,
    __spawn = __spawn,
    _apply = _apply,
}

