local clock = require('clock')
local etcd_client = require('etcd-client')
local fiber = require('fiber')
local log = require('log')

local function validate(roles_cfg)
    assert(type(roles_cfg) == 'table')
    assert(type(roles_cfg.endpoints) == 'table')
    assert(type(roles_cfg.endpoints[1]) == 'string')
    assert(type(roles_cfg.username) == 'string')
    assert(type(roles_cfg.password) == 'string')
    assert(type(roles_cfg.prefix) == 'string')
end

local watchdog = nil

local function string_replace(base, old_fragment, new_fragment)
    local i, j = base:find(old_fragment)

    if i == nil then
        return base
    end

    local prefix = ''
    if i > 1 then
        prefix = base:sub(1, i - 1)
    end

    local suffix = ''
    if j < base:len() then
        suffix = base:sub(j + 1, base:len())
    end

    return prefix .. new_fragment .. suffix
end

local function get_migrations_from_range_resp(resp, prefix)
    local kvs = resp.kvs

    local migrations = {}

    for _, v in ipairs(kvs) do
        local key = string_replace(v.key, prefix, '')
        local value = v.value
        migrations[key] = value
    end

    return migrations
end

local function get_migrations_from_watch_resp(resp, prefix)
    local event = resp.events[1]
    local kv = event.kv

    local migrations = {}

    local key = string_replace(kv.key, prefix, '')
    local value = kv.value
    migrations[key] = value

    return migrations
end


local function migrate(migrations)
    if not box.info.ro then
        local migrations_state_space_name = '_migrations_state'
        local migrations_state_space = box.space[migrations_state_space_name]
        if migrations_state_space == nil then
            migrations_state_space = box.schema.space.create(migrations_state_space_name)

            migrations_state_space:format({
                {name = 'migration_id', type = 'string'},
                {name = 'apply_finished', type = 'datetime'},
            })

            migrations_state_space:create_index('primary', {parts = {'migration_id'}})
        end

        local migrations_history_space_name = '_migrations_history'
        local migrations_history_space = box.space[migrations_history_space_name]
        if migrations_history_space == nil then
            migrations_history_space = box.schema.space.create(migrations_history_space_name)

            migrations_history_space:format({
                {name = 'action_id', type = 'integer'},
                {name = 'migration_id', type = 'string'},
                {name = 'action_kind', type = 'string'},
                {name = 'apply_finished', type = 'datetime'},
            })

            local sequence_name = migrations_history_space_name .. '_seq'
            box.schema.sequence.create(sequence_name, {if_not_exists = true})

            migrations_history_space:create_index('primary', {parts = {'action_id'}, sequence = sequence_name})
            migrations_history_space:create_index('migration_id', {parts = {'migration_id'}, unique = false})
        end
    else
        while true do
            local ok = pcall(function()
                assert(box.space['_migrations_history'] ~= nil)
                assert(#box.space['_migrations_history'].indexes == 2)
            end)

            if ok then
                break
            else
                fiber.sleep(0.1)
            end
        end
    end

    local order = {}
    for migration_id, _ in pairs(migrations) do
        table.insert(order, migration_id)
    end
    table.sort(order)

    for _, migration_id in ipairs(order) do
        local migration = migrations[migration_id]

        if box.space['_migrations_state']:get(migration_id) ~= nil then
            goto continue
        end

        if not box.info.ro then
            box.space['_migrations_history']:insert{box.NULL, migration_id, 'upgrade_started', require('datetime').now()}

            loadstring(migration)()

            box.space['_migrations_history']:insert{box.NULL, migration_id, 'upgrade_finished', require('datetime').now()}
            box.space['_migrations_state']:replace{migration_id, require('datetime').now()}
        else
            while true do
                local ok = box.space['_migrations_state']:get(migration_id) ~= nil

                if ok then
                    break
                else
                    fiber.sleep(0.1)
                end
            end
        end

        ::continue::
    end

    return true
end

local function apply(roles_cfg)
    if watchdog ~= nil then
        watchdog:cancel()
    end

    local client, err = etcd_client.new{
        endpoints = roles_cfg.endpoints,
        name = roles_cfg.username,
        password = roles_cfg.password
    }
    assert(err == nil, err)

    local start_key = roles_cfg.prefix
    local end_key = etcd_client.NEXT(start_key)
    local opts = {range_end = end_key}

    local resp, err = client:range(start_key, end_key)
    if err ~= nil then
        log.warn('migrator: failed to init migrate: %s', err)
    end
    local migrations = get_migrations_from_range_resp(resp, roles_cfg.prefix)
    migrate(migrations)

    watchdog = fiber.create(function()
        fiber.name("migrator fiber")

        -- Hard-coded minimum delay.
        local DELAY = 1
        local ok
        local ret
        while true do
            -- Do nothing if flag is_watcher_cancelled is set. In this case
            -- _has_watcher is false and _watch_id is nil.
            if client.is_watcher_cancelled then
                log.warn('migrator: etcd: watchcreate: watcher is cancelled')
                return
            end
            local start_time = clock.monotonic()
            ok, ret = pcall(client.watchcreate, client, start_key, opts)
            if ok then
                break
            end
            log.warn('migrator: etcd: watchcreate: ' .. tostring(ret))
            local spent_time = clock.monotonic() - start_time
            fiber.sleep(math.max(DELAY - spent_time, 0))
        end

        local watch_id = ret.watch_id

        while true do
            local start_time = clock.monotonic()
            local ok, ret = pcall(client.watchwait, client, watch_id)
            -- Do nothing if flag is_watcher_cancelled is set. In this case
            -- _has_watcher is false and _watch_id is nil.
            if client.is_watcher_cancelled then
                log.warn('migrator: etcd: watchwait: watcher is cancelled')
                return
            end
            if ok then
                local key = ret.events[1].kv.key
                log.info(('migrator: etcd: new config was detected in %q'):format(key))

                local migrations = get_migrations_from_watch_resp(ret, roles_cfg.prefix)
                migrate(migrations)
            else
                log.warn('migrator: etcd: watchwait: ' .. tostring(ret))
                local spent_time = clock.monotonic() - start_time
                fiber.sleep(math.max(DELAY - spent_time, 0))
            end
            -- Throw an error if fiber is cancelled.
            fiber.testcancel()
        end
    end)
end

local function stop()
    if watchdog ~= nil then
        watchdog:cancel()
        watchdog = nil
    end
end

return {
    validate = validate,
    apply = apply,
    stop = stop,
}
