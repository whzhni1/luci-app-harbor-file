-- HarborFile filesystem/media/upload/archive api handlers
local unpack = table.unpack or unpack
local _ = require("luci.i18n").translate
local util = require "luci.controller.harbor_file.util"
local M = {}

function M.api_navigation()
    local preferences = util.read_preferences()
    local quick_access = util.build_quick_access(preferences)
    local folders = util.list_root_folders()
    util.write_json({
        code = 0,
        message = "success",
        data = {
            quick_access = quick_access,
            home_dir = preferences.home_dir,
            folders = folders,
            drives = util.list_drives()
        }
    })
end

function M.api_list()
    local path = util.normalize_path(luci.http.formvalue("path"))
    if not path then
        util.write_json({ code = 1, message = "invalid path" })
        return
    end

    local preferences = util.read_preferences()
    local items, err = util.list_directory(path, preferences)
    if not items then
        util.write_json({ code = 2, message = err or "list failed" })
        return
    end
    local available, total, operation_space_margin = util.get_directory_space_info(path)
    local has_operation_space = available ~= nil and available >= (operation_space_margin or 0)
    available = available or 0
    total = total or 0
    operation_space_margin = operation_space_margin or 0

    util.write_json({
        code = 0,
        message = "success",
        data = {
            path = path,
            parent = util.parent_path(path),
            available_bytes = available,
            total_bytes = total,
            operation_space_margin = operation_space_margin,
            has_operation_space = has_operation_space,
            items = items
        }
    })
end

function M.api_create_directory()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end
    local target_dir, err = util.get_writable_directory(luci.http.formvalue("target_dir"))
    local name = luci.http.formvalue("name")
    if not target_dir or not util.validate_upload_name(name) then
        util.write_json_status(400, "Bad Request", { code = 1, message = err or "invalid directory name" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end
    local has_space, available, space_err = util.ensure_directory_space(target_dir, 0)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = 0 }
        })
        return
    end

    local path = util.join_path(target_dir, name)
    if nixio_fs.lstat(path) then
        util.write_json_status(409, "Conflict", { code = 1, message = "target already exists" })
        return
    end
    if not nixio_fs.mkdir(path) then
        util.write_json_status(500, "Create Failed", { code = 1, message = "create directory failed" })
        return
    end
    util.write_json({ code = 0, message = "success", data = { path = path } })
end

function M.api_create_file()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end
    local target_dir, err = util.get_writable_directory(luci.http.formvalue("target_dir"))
    local name = luci.http.formvalue("name")
    if not target_dir or not util.validate_upload_name(name) then
        util.write_json_status(400, "Bad Request", { code = 1, message = err or "invalid file name" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end
    local has_space, available, space_err = util.ensure_directory_space(target_dir, 0)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = 0 }
        })
        return
    end

    local path = util.join_path(target_dir, name)
    if nixio_fs.lstat(path) then
        util.write_json_status(409, "Conflict", { code = 1, message = "target already exists" })
        return
    end

    local fd, open_err = io.open(path, "wb")
    if not fd then
        util.write_json_status(500, "Create Failed", { code = 1, message = open_err or "create file failed" })
        return
    end
    fd:close()
    util.write_json({ code = 0, message = "success", data = { path = path } })
end

function M.api_rename()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end
    local path = util.normalize_path(luci.http.formvalue("path"))
    local new_name = luci.http.formvalue("new_name")
    local stat = path and path ~= "/" and nixio_fs.lstat(path) or nil
    if not stat or not util.validate_upload_name(new_name) then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid path or name" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(path) then
        return util.deny_system_operation()
    end

    local parent, err = util.get_writable_directory(util.parent_path(path))
    if not parent then
        util.write_json_status(403, "Forbidden", { code = 1, message = err })
        return
    end
    local has_space, available, space_err, required = util.ensure_directory_space(parent, 0)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = required or 0 }
        })
        return
    end
    if stat.type == "dir" and util.contains_mount(path, util.read_mount_paths()) then
        util.write_json_status(409, "Conflict", { code = 1, message = "directory contains a mount point" })
        return
    end
    local target = util.join_path(parent, new_name)
    if target ~= path and nixio_fs.lstat(target) then
        util.write_json_status(409, "Conflict", { code = 1, message = "target already exists" })
        return
    end
    if target ~= path and not os.rename(path, target) then
        util.write_json_status(500, "Rename Failed", { code = 1, message = "rename failed" })
        return
    end
    util.write_json({ code = 0, message = "success", data = { path = target } })
end

function M.api_delete()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat = path and path ~= "/" and nixio_fs.lstat(path) or nil
    if not stat then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid path" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(path) then
        return util.deny_system_operation()
    end

    local parent, err = util.get_writable_directory(util.parent_path(path))
    if not parent then
        util.write_json_status(403, "Forbidden", { code = 1, message = err })
        return
    end
    if stat.type == "dir" and util.contains_mount(path, util.read_mount_paths()) then
        util.write_json_status(409, "Conflict", { code = 1, message = "directory contains a mount point" })
        return
    end
    local ok, remove_err = util.remove_tree(path)
    if not ok then
        util.write_json_status(500, "Delete Failed", { code = 1, message = remove_err })
        return
    end
    util.write_json({ code = 0, message = "success", data = {} })
end

local function transfer_path(mode)
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end
    local source = util.normalize_path(luci.http.formvalue("source"))
    local target_dir, target_err = util.get_writable_directory(luci.http.formvalue("target_dir"))
    local source_stat = source and source ~= "/" and nixio_fs.lstat(source) or nil
    if not source_stat or not target_dir then
        util.write_json_status(400, "Bad Request", { code = 1, message = target_err or ("invalid source path: " .. tostring(luci.http.formvalue("source") or "")) })
        return
    end
    if not util.system_operations_allowed() then
        if util.is_system_path(target_dir) then
            return util.deny_system_operation()
        end
        if mode == "move" and util.is_system_path(source) then
            return util.deny_system_operation()
        end
    end
    if source_stat.type ~= "reg" and source_stat.type ~= "dir" and source_stat.type ~= "lnk" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "unsupported source type" })
        return
    end
    if source_stat.type == "dir" and (util.is_child_path(target_dir, source) or util.contains_mount(source, util.read_mount_paths())) then
        util.write_json_status(409, "Conflict", { code = 1, message = "invalid target directory or mounted source" })
        return
    end

    local name = source:match("([^/]+)$")
    local target = util.join_path(target_dir, name)
    if target == source or nixio_fs.lstat(target) then
        util.write_json_status(409, "Conflict", { code = 1, message = "target already exists" })
        return
    end
    if mode == "move" and not nixio_fs.access(util.parent_path(source), "w") then
        util.write_json_status(403, "Forbidden", { code = 1, message = "source directory is not writable" })
        return
    end

    local ok
    local err
    if mode == "move" and os.rename(source, target) then
        ok = true
    else
        local required_size = source_stat.type == "reg" and (tonumber(source_stat.size) or 0) or 0
        local has_space, available, space_err, required = util.ensure_directory_space(target_dir, required_size)
        if not has_space then
            util.write_json_status(507, "Insufficient Storage", {
                code = 2,
                message = space_err or util.insufficient_space_message,
                data = { available_bytes = available, required_bytes = required or 0 }
            })
            return
        end
        ok, err = util.copy_tree(source, target)
        if ok and mode == "move" then
            ok, err = util.remove_tree(source)
            if not ok then
                util.remove_tree(target)
            end
        end
    end
    if not ok then
        util.remove_tree(target)
        util.write_json_status(500, "Transfer Failed", { code = 1, message = err or "file operation failed" })
        return
    end
    util.write_json({ code = 0, message = "success", data = { path = target } })
end

local function parse_path_array_param(name)
    local jsonc = require "luci.jsonc"
    local ok, values = pcall(jsonc.parse, luci.http.formvalue(name) or "")
    if not ok or type(values) ~= "table" or #values == 0 then
        return nil, "invalid path list"
    end
    return values
end

local function validate_batch_sources(paths, mode, target_dir)
    local nixio_fs = require "nixio.fs"
    local seen_paths = {}
    local seen_names = {}
    local items = {}
    local mounts = util.read_mount_paths()
    local system_disabled_message = _("System folder operations are disabled")
    for _, raw_path in ipairs(paths or {}) do
        local path = util.normalize_path(raw_path)
        local stat = path and path ~= "/" and nixio_fs.lstat(path) or nil
        if not stat then
            return nil, raw_path, "invalid source path: " .. tostring(raw_path or "")
        end
        if seen_paths[path] then
            return nil, path, "duplicate source path"
        end
        if stat.type ~= "reg" and stat.type ~= "dir" and stat.type ~= "lnk" then
            return nil, path, "unsupported source type"
        end
        if not util.system_operations_allowed() and (mode == "move" or mode == "delete") and util.is_system_path(path) then
            return nil, path, system_disabled_message
        end
        if stat.type == "dir" and util.contains_mount(path, mounts) then
            return nil, path, "directory contains a mount point"
        end
        if target_dir and stat.type == "dir" and util.is_child_path(target_dir, path) then
            return nil, path, "invalid target directory"
        end
        local name = path:match("([^/]+)$")
        if not name or name == "" then
            return nil, path, "invalid source path: " .. tostring(path or "")
        end
        if target_dir and seen_names[name] then
            return nil, path, "duplicate target name"
        end
        seen_paths[path] = true
        seen_names[name] = true
        table.insert(items, { path = path, stat = stat, name = name })
    end
    return items
end

local function transfer_one(mode, item, target_dir)
    local nixio_fs = require "nixio.fs"
    local source = item.path
    local target = util.join_path(target_dir, item.name)
    if target == source or nixio_fs.lstat(target) then
        return false, "target already exists"
    end
    if mode == "move" and not nixio_fs.access(util.parent_path(source), "w") then
        return false, "source directory is not writable"
    end
    if mode == "move" and os.rename(source, target) then
        return true
    end
    local ok, err = util.copy_tree(source, target)
    if ok and mode == "move" then
        ok, err = util.remove_tree(source)
        if not ok then
            util.remove_tree(target)
        end
    end
    if not ok then
        util.remove_tree(target)
    end
    return ok, err
end

local function write_batch_failure(status, reason, message, processed, success_count, failed_path)
    util.write_json_status(status, reason, {
        code = 1,
        message = message or "batch operation failed",
        data = {
            processed = processed or 0,
            success_count = success_count or 0,
            failed_path = failed_path or ""
        }
    })
end

local function batch_transfer_path(mode)
    if not util.validate_write_request() then
        return
    end

    local rename_map_json = luci.http.formvalue("rename_map")
    local rename_map = {}
    if rename_map_json and rename_map_json ~= "" then
        local jsonc = require "luci.jsonc"
        local ok, data = pcall(jsonc.parse, rename_map_json)
        if ok and type(data) == "table" then
            rename_map = data
        end
    end

    local conflict_action = luci.http.formvalue("conflict_action") or "skip"

    local paths, parse_err = parse_path_array_param("sources")
    if not paths then
        util.write_json_status(400, "Bad Request", { code = 1, message = parse_err })
        return
    end

    local target_dir, target_err = util.get_writable_directory(luci.http.formvalue("target_dir"))
    if not target_dir then
        util.write_json_status(400, "Bad Request", { code = 1, message = target_err or "invalid target directory" })
        return
    end

    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end

    local items, failed_path, err = validate_batch_sources(paths, mode, target_dir)
    if not items then
        write_batch_failure(409, "Conflict", err, 0, 0, failed_path)
        return
    end

    local required_size = 0
    for _, item in ipairs(items) do
        if item.stat.type == "reg" then
            required_size = required_size + (tonumber(item.stat.size) or 0)
        end
    end

    local has_space, available, space_err, required = util.ensure_directory_space(target_dir, required_size)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = required or required_size }
        })
        return
    end

    local nixio_fs = require "nixio.fs"
    local success_count = 0

    for index, item in ipairs(items) do
        local target_name = rename_map[item.name] or item.name
        local target = util.join_path(target_dir, target_name)
        local target_stat = nixio_fs.lstat(target)
        local should_skip = false

        if target_stat then
            if conflict_action == "replace" then
                local ok, remove_err = util.remove_tree(target)
                if not ok then
                    write_batch_failure(500, "Remove Failed", remove_err, index - 1, success_count, item.path)
                    return
                end
            elseif conflict_action == "skip" then
                success_count = success_count + 1
                should_skip = true
            elseif conflict_action == "rename" then
                local base = target_name
                local name_no_ext, ext
                local dot_pos = base:find("%.[^.]*$")
                if dot_pos then
                    name_no_ext = base:sub(1, dot_pos - 1)
                    ext = base:sub(dot_pos)
                else
                    name_no_ext = base
                    ext = ""
                end
                local count = 1
                while true do
                    local new_name = name_no_ext .. " (" .. count .. ")" .. ext
                    local new_target = util.join_path(target_dir, new_name)
                    if not nixio_fs.lstat(new_target) then
                        target_name = new_name
                        target = new_target
                        break
                    end
                    count = count + 1
                end
            else
                write_batch_failure(409, "Conflict", "target already exists", index - 1, success_count, item.path)
                return
            end
        end

        if not should_skip then
            local original_name = item.name
            item.name = target_name
            local ok, op_err = transfer_one(mode, item, target_dir)
            item.name = original_name
            if not ok then
                write_batch_failure(500, "Transfer Failed", op_err, index - 1, success_count, item.path)
                return
            end
            success_count = success_count + 1
        end
    end

    util.write_json({ code = 0, message = "success", data = { processed = #items, success_count = success_count } })
end

local function batch_delete_paths()
    if not util.validate_write_request() then
        return
    end
    local paths, parse_err = parse_path_array_param("paths")
    if not paths then
        util.write_json_status(400, "Bad Request", { code = 1, message = parse_err })
        return
    end
    local items, failed_path, err = validate_batch_sources(paths, "delete")
    if not items then
        write_batch_failure(409, "Conflict", err, 0, 0, failed_path)
        return
    end

    local success_count = 0
    for index, item in ipairs(items) do
        local parent, parent_err = util.get_writable_directory(util.parent_path(item.path))
        if not parent then
            write_batch_failure(403, "Forbidden", parent_err, index - 1, success_count, item.path)
            return
        end
        local ok, remove_err = util.remove_tree(item.path)
        if not ok then
            write_batch_failure(500, "Delete Failed", remove_err, index - 1, success_count, item.path)
            return
        end
        success_count = success_count + 1
    end
    util.write_json({ code = 0, message = "success", data = { processed = #items, success_count = success_count } })
end

function M.api_copy()
    transfer_path("copy")
end

function M.api_move()
    transfer_path("move")
end

function M.api_batch_copy()
    batch_transfer_path("copy")
end

function M.api_batch_move()
    batch_transfer_path("move")
end

function M.api_batch_delete()
    batch_delete_paths()
end

function M.api_archive_create_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    local current = util.archive.read_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.archive.busy_response(current)
        return
    end

    local paths, parse_err = parse_path_array_param("sources")
    if not paths then
        util.write_json_status(400, "Bad Request", { code = 1, message = parse_err })
        return
    end

    local format_key = tostring(luci.http.formvalue("format") or ""):lower()
    local format_info = util.archive.create_formats[format_key]
    if not format_info then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Unsupported archive format") })
        return
    end

    local first_path = util.normalize_path(paths[1])
    local requested_dir = util.normalize_path(luci.http.formvalue("target_dir"))
    local default_dir = first_path and util.parent_path(first_path) or nil
    local target_dir = (requested_dir or default_dir)
    target_dir = target_dir and select(1, util.get_writable_directory(target_dir)) or nil
    if not target_dir then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid target directory" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end

    local items, failed_path, err = validate_batch_sources(paths, "copy", target_dir)
    if not items then
        write_batch_failure(409, "Conflict", err, 0, 0, failed_path)
        return
    end
    -- All sources must share one parent directory; that directory is used as
    -- the working directory for tar/zip.  The output file itself may be
    -- written to a different (user-chosen) target directory.
    local source_dir = util.parent_path(items[1].path)
    local same_directory_message = _("Archive sources must be in the same directory")
    for _, item in ipairs(items) do
        if util.parent_path(item.path) ~= source_dir then
            util.write_json_status(409, "Conflict", { code = 1, message = same_directory_message })
            return
        end
    end
    if format_info.single_file and (#items ~= 1 or items[1].stat.type ~= "reg") then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("This archive format only supports one regular file") })
        return
    end

    local output_name = util.archive.ensure_extension(luci.http.formvalue("output_name"), format_key)
    if not util.validate_upload_name(output_name) then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid file name" })
        return
    end
    local output_path = util.join_path(target_dir, output_name)
    local existing = nixio_fs.lstat(output_path)
    local overwrite = luci.http.formvalue("overwrite") == "1"
    if existing then
        if not overwrite then
            -- HTTP 200 + code 3: this is a confirmation prompt, not an error,
            -- so the browser console stays clean.
            util.write_json({ code = 3, message = _("File already exists") })
            return
        end
        if existing.type == "dir" then
            util.write_json_status(409, "Conflict", { code = 1, message = _("A directory already uses this name") })
            return
        end
        nixio_fs.unlink(output_path)
    end

    local required_size = util.archive.source_size(items)
    local has_space, available, space_err, required = util.ensure_directory_space(target_dir, required_size)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = required or required_size }
        })
        return
    end
    if not util.find_executable(format_info.command) then
        util.write_json_status(424, "Dependency Required", {
            code = 2,
            message = _("Archive command not found"),
            data = {
                missing_tool = format_info.command,
                package_name = util.tool_package_name(format_info.command),
                installer = util.detect_package_installer()
            }
        })
        return
    end

    local names = {}
    local sources = {}
    for _, item in ipairs(items) do
        table.insert(names, item.name)
        table.insert(sources, item.path)
    end
    local task = {
        task_id = util.archive.task_id(),
        mode = "create",
        state = "pending",
        done = false,
        success = false,
        message = _("Preparing archive"),
        exit_code = nil,
        format = format_key,
        target_dir = target_dir,
        source_dir = source_dir,
        output_path = output_path,
        names = names,
        sources = sources,
        source_count = #sources,
        started_at = util.current_timestamp(),
        finished_at = nil,
        pid = nil
    }
    util.archive.start_response(task)
end

function M.api_archive_extract_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    local current = util.archive.read_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.archive.busy_response(current)
        return
    end

    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat = path and path ~= "/" and nixio_fs.lstat(path) or nil
    local format_key = path and util.archive.detect_extract_format(path) or nil
    local format_info = format_key and util.archive.extract_formats[format_key] or nil
    if not path or not stat or stat.type ~= "reg" or not format_info then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Unsupported archive format") })
        return
    end

    -- User-supplied destination directory (defaults to the archive's own dir).
    local requested_dir = util.normalize_path(luci.http.formvalue("target_dir"))
    local target_dir, parent_err = util.get_writable_directory(requested_dir or util.parent_path(path))
    if not target_dir then
        util.write_json_status(403, "Forbidden", { code = 1, message = parent_err or "directory is not writable" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end

    local base_name = util.archive.file_name(path)
    local destination_name = util.archive.strip_suffix(base_name, format_key)
    if not destination_name or destination_name == "" or destination_name == "." then
        destination_name = "archive_extract"
    end
    local destination_path = util.join_path(target_dir, destination_name)
    local overwrite = luci.http.formvalue("overwrite") == "1"
    if nixio_fs.lstat(destination_path) then
        if not overwrite then
            -- HTTP 200 + code 3: a confirmation prompt, not an error.
            util.write_json({ code = 3, message = _("File already exists") })
            return
        end
    end

    local has_space, available, space_err, required = util.ensure_directory_space(target_dir, 0)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = required or 0 }
        })
        return
    end
    if not util.find_executable(format_info.command) then
        util.write_json_status(424, "Dependency Required", {
            code = 2,
            message = _("Archive command not found"),
            data = {
                missing_tool = format_info.command,
                package_name = util.tool_package_name(format_info.command),
                installer = util.detect_package_installer()
            }
        })
        return
    end

    local task = {
        task_id = util.archive.task_id(),
        mode = "extract",
        state = "pending",
        done = false,
        success = false,
        message = _("Preparing archive"),
        exit_code = nil,
        format = format_key,
        path = path,
        destination_path = destination_path,
        container = format_info.container == true,
        overwrite = overwrite,
        source_count = 1,
        started_at = util.current_timestamp(),
        finished_at = nil,
        pid = nil
    }
    util.archive.start_response(task)
end

function M.api_archive_status()
    local task_id = luci.http.formvalue("task_id")
    if type(task_id) ~= "string" or task_id == "" then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Invalid task id") })
        return
    end

    local task = util.archive.read_state()
    if not task or task.task_id ~= task_id then
        util.write_json_status(404, "Not Found", { code = 1, message = _("Archive task not found") })
        return
    end

    util.write_json({ code = 0, message = "success", data = util.archive.response(task) })
end

local function validate_preview_file(path, expected_type)
    local nixio_fs = require "nixio.fs"
    if not path then
        return nil, "invalid path"
    end

    local stat = nixio_fs.stat(path)
    if not stat or stat.type ~= "reg" then
        return nil, "file not found"
    end

    if util.classify_preview(path, path) ~= expected_type then
        return nil, "file type is not supported"
    end

    return stat
end

local function validate_text_edit_file(path)
    -- Editing is no longer limited by a fixed file size.  The client reads in
    -- pages and only materializes all pages when the user explicitly saves.
    return validate_preview_file(path, "text")
end

local function write_text_atomic(path, content, source_stat)
    local nixio_fs = require "nixio.fs"
    local file_name = path:match("([^/]+)$") or "text"
    local parent = util.parent_path(path)
    local temp_path = util.join_path(
        parent,
        "." .. file_name .. ".harbor_file_tmp_" ..
            tostring(math.floor(util.video_now_ms() or 0)) .. "_" .. tostring(math.floor(os.time() % 100000))
    )
    local fd, open_err = io.open(temp_path, "wb")
    if not fd then
        return nil, open_err or "open temporary file failed"
    end

    local ok, write_ok, write_err = pcall(fd.write, fd, content or "")
    fd:close()
    if not ok or write_ok == nil then
        nixio_fs.unlink(temp_path)
        return nil, tostring(write_err or "write temporary file failed")
    end

    local mode_text = source_stat and source_stat.modestr or nil
    if type(mode_text) == "string" and mode_text ~= "" then
        pcall(nixio_fs.chmod, temp_path, mode_text)
    end

    if not os.rename(temp_path, path) then
        nixio_fs.unlink(temp_path)
        return nil, "replace file failed"
    end

    local stat = nixio_fs.stat(path)
    if not stat or stat.type ~= "reg" then
        return nil, "verify saved file failed"
    end
    return stat
end

local function validate_download_file(path)
    local nixio_fs = require "nixio.fs"
    if not path then
        return nil, "invalid path"
    end

    local stat = nixio_fs.stat(path)
    if not stat or stat.type ~= "reg" then
        return nil, "file not found"
    end

    return stat
end

local function sanitize_download_name(name)
    local value = tostring(name or ""):gsub("[\\/\r\n\"]", "_"):gsub("[%z\1-\31\127]", "_")
    if value == "" or value == "." or value == ".." then
        return "download"
    end
    return value
end

local function encode_rfc5987(value)
    return (tostring(value or ""):gsub("([^%w%!%#%$%&%+%-%._%~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end))
end

function M.api_download()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_download_file(path)
    if not stat then
        util.write_plain_status(400, "Bad Request", err)
        return
    end

    local fd = io.open(path, "rb")
    if not fd then
        util.write_plain_status(500, "Internal Server Error", "open file failed")
        return
    end

    local file_name = path:match("([^/]+)$") or "download"
    local safe_name = sanitize_download_name(file_name)
    util.set_status(200, "OK")
    luci.http.header("Content-Type", "application/octet-stream")
    luci.http.header("Content-Length", tostring(stat.size or 0))
    luci.http.header("Content-Disposition",
        "attachment; filename=\"" .. safe_name .. "\"; filename*=UTF-8''" .. encode_rfc5987(file_name))
    luci.http.header("Cache-Control", "no-store")
    luci.http.header("X-Content-Type-Options", "nosniff")

    while true do
        local data = fd:read(65536)
        if not data or #data == 0 then
            break
        end
        luci.http.write(data)
    end

    fd:close()
end


function M.api_read_text()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_preview_file(path, "text")
    if not stat then
        util.write_json({ code = 1, message = err })
        return
    end
    local fd = io.open(path, "rb")
    if not fd then
        util.write_json({ code = 2, message = "open file failed" })
        return
    end
    -- Compatibility endpoint with no application-level size limit.
    local content = fd:read("*a") or ""
    fd:close()
    util.write_json({
        code = 0,
        message = "success",
        data = {
            path = path,
            content = content,
            truncated = false,
            size = tonumber(stat.size) or 0,
            mtime = tonumber(stat.mtime) or 0
        }
    })
end

function M.api_read_binary()
    local nixio_fs = require "nixio.fs"
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat = path and nixio_fs.stat(path) or nil
    if not path or not stat or stat.type ~= "reg" then
        util.write_json({ code = 1, message = "file not found" })
        return
    end
    local file_size = tonumber(stat.size) or 0
    local start_offset = util.parse_binary_number(luci.http.formvalue("offset"), 0)
    local size_kb_value = luci.http.formvalue("size_kb")
    local read_kb
    if size_kb_value ~= nil and size_kb_value ~= "" then
        read_kb = util.parse_binary_number(size_kb_value, nil)
    else
        local read_size = util.parse_binary_number(luci.http.formvalue("size"), util.default_binary_read_kb * 1024)
        read_kb = read_size and math.ceil(read_size / 1024) or nil
    end
    if not start_offset or not read_kb or read_kb < 1 or read_kb > util.max_binary_read_kb then
        util.write_json({ code = 1, message = "invalid range" })
        return
    end
    local read_limit = read_kb * 1024
    if start_offset > file_size then
        start_offset = file_size
    end

    local fd = io.open(path, "rb")
    if not fd then
        util.write_json({ code = 2, message = "open file failed" })
        return
    end
    if start_offset > 0 then
        if not fd:seek("set", start_offset) then
            fd:close()
            util.write_json({ code = 2, message = "seek file failed" })
            return
        end
    end

    local content = fd:read(read_limit + 1) or ""
    fd:close()
    local truncated = #content > read_limit or (start_offset + #content) < file_size
    if truncated then
        content = content:sub(1, read_limit)
    end

    local rows = {}
    for relative_offset = 1, #content, 16 do
        local chunk = content:sub(relative_offset, relative_offset + 15)
        local hex = {}
        local ascii = {}
        for index = 1, #chunk do
            local byte = chunk:byte(index)
            if index == 9 then
                table.insert(hex, " ")
                table.insert(ascii, " ")
            end
            table.insert(hex, string.format("%02x", byte))
            table.insert(ascii, byte > 32 and byte <= 126 and string.char(byte) or ".")
        end
        table.insert(rows, {
            line = #rows + 1,
            offset = util.hex32(start_offset + relative_offset - 1),
            hex = table.concat(hex, " "),
            ascii = table.concat(ascii, "")
        })
    end

    util.write_json({
        code = 0,
        message = "success",
        data = {
            path = path,
            rows = rows,
            truncated = truncated,
            max_size = util.max_binary_read_size,
            max_kb = util.max_binary_read_kb,
            size = file_size,
            offset = start_offset,
            requested_size = read_limit,
            requested_kb = read_kb,
            read_size = #content,
            lines = #rows,
            mtime = tonumber(stat.mtime) or 0
        }
    })
end

function M.api_save_text()
    if not util.validate_write_request() then
        return
    end

    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_text_edit_file(path)
    if not stat then
        util.write_json_status(400, "Bad Request", { code = 1, message = err or "invalid path" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(path) then
        return util.deny_system_operation()
    end

    local parent, parent_err = util.get_writable_directory(util.parent_path(path))
    if not parent then
        util.write_json_status(403, "Forbidden", { code = 1, message = parent_err or "directory is not writable" })
        return
    end

    local content = luci.http.formvalue("content")
    if type(content) ~= "string" then
        content = ""
    end
    local has_space, available, space_err, required = util.ensure_directory_space(parent, #content)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = required or 0 }
        })
        return
    end

    local saved_stat, save_err = write_text_atomic(path, content, stat)
    if not saved_stat then
        util.write_json_status(500, "Save Failed", { code = 1, message = save_err or "save file failed" })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = {
            path = path,
            parent = parent,
            size = tonumber(saved_stat.size) or 0,
            mtime = tonumber(saved_stat.mtime) or 0
        }
    })
end


-- Server-side edit session ---------------------------------------------------------
-- The session is a piece table: base-file ranges and small patch files are kept as
-- pieces. Applying a patch only updates metadata and writes the changed bytes; a
-- full streamed materialisation happens once, on explicit Save.
function M.api_read_editor_file()
    local nixio_fs = require "nixio.fs"
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat = path and nixio_fs.stat(path) or nil
    if not path or not stat or stat.type ~= "reg" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "file not found" })
        return
    end
    local fd = io.open(path, "rb")
    if not fd then
        util.write_json_status(500, "Read Failed", { code = 1, message = "open file failed" })
        return
    end
    local content = fd:read("*a") or ""
    fd:close()
    util.write_json({
        code = 0,
        message = "success",
        data = {
            path = path,
            size = tonumber(stat.size) or 0,
            mtime = tonumber(stat.mtime) or 0,
            encoding = "base64",
            content_base64 = util.harbor_file_base64_encode(content)
        }
    })
end

function M.api_save_editor_upload()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end
    local path = util.normalize_path(luci.http.formvalue("path", true))
    local source_stat = path and nixio_fs.stat(path) or nil
    if not path or not source_stat or source_stat.type ~= "reg" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "file not found" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(path) then
        return util.deny_system_operation()
    end
    local parent, parent_err = util.get_writable_directory(util.parent_path(path))
    if not parent then
        util.write_json_status(403, "Forbidden", { code = 1, message = parent_err or "directory is not writable" })
        return
    end
    local has_space, available, space_err, required = util.ensure_directory_space(parent, 0)
    if not has_space then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = space_err or util.insufficient_space_message,
            data = { available_bytes = available, required_bytes = required or 0 }
        })
        return
    end

    local file_name = path:match("([^/]+)$") or "file"
    local state = {
        temp_path = parent .. "/." .. file_name .. ".harbor_blob_" .. tostring(os.time()) .. "_" ..
            tostring(math.floor(util.video_now_ms() or 0)),
        written = 0,
        started = false,
        completed = false,
        error = nil,
        fd = nil
    }

    local function fail(message)
        if not state.error then
            state.error = message
        end
        if state.fd then
            state.fd:close()
            state.fd = nil
        end
        if state.temp_path then
            nixio_fs.unlink(state.temp_path)
        end
    end

    luci.http.setfilehandler(function(meta, chunk, eof)
        if state.error then
            return
        end
        if not meta or meta.name ~= "content" then
            return
        end
        if not state.started then
            state.fd = io.open(state.temp_path, "wb")
            if not state.fd then
                fail("create temporary file failed")
                return
            end
            state.started = true
        end
        if chunk and #chunk > 0 then
            if not state.fd:write(chunk) then
                fail("write temporary file failed")
                return
            end
            state.written = state.written + #chunk
        end
        if eof then
            state.fd:close()
            state.fd = nil
            state.completed = true
        end
    end)

    local parsed = pcall(function()
        luci.http.formvalue("content")
    end)
    if not parsed and not state.error then
        fail("parse upload failed")
    elseif not state.started and not state.error then
        fail("upload content is missing")
    elseif not state.completed and not state.error then
        fail("upload is incomplete")
    end
    if state.error then
        util.write_json_status(500, "Upload Failed", { code = 1, message = state.error })
        return
    end

    local mode_text = source_stat.modedec or source_stat.modestr
    if mode_text then
        pcall(nixio_fs.chmod, state.temp_path, tostring(mode_text))
    end
    if not os.rename(state.temp_path, path) then
        nixio_fs.unlink(state.temp_path)
        util.write_json_status(500, "Save Failed", { code = 1, message = "replace file failed" })
        return
    end
    if mode_text then
        pcall(nixio_fs.chmod, path, tostring(mode_text))
    end
    local saved_stat = nixio_fs.stat(path)
    if not saved_stat or saved_stat.type ~= "reg" then
        util.write_json_status(500, "Save Failed", { code = 1, message = "verify saved file failed" })
        return
    end
    util.write_json({
        code = 0,
        message = "success",
        data = {
            path = path,
            size = tonumber(saved_stat.size) or 0,
            mtime = tonumber(saved_stat.mtime) or 0,
            mode = tostring(saved_stat.modedec or mode_text or "")
        }
    })
end

function M.api_image()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_preview_file(path, "image")
    if not stat then
        util.write_plain_status(400, "Bad Request", err)
        return
    end

    local fd = io.open(path, "rb")
    if not fd then
        util.write_plain_status(500, "Internal Server Error", "open file failed")
        return
    end

    local mime = util.image_mime_map[util.get_ext(path)] or "application/octet-stream"
    util.set_status(200, "OK")
    luci.http.header("X-Content-Type-Options", "nosniff")
    luci.http.header("Content-Length", tostring(stat.size or 0))
    luci.http.header("Cache-Control", "no-store")
    luci.http.header("Content-Disposition", "inline")
    luci.http.prepare_content(mime)

    while true do
        local data = fd:read(65536)
        if not data or #data == 0 then
            break
        end
        luci.http.write(data)
    end
    fd:close()
end

function M.api_thumbnail()
    local nixio_fs = require "nixio.fs"
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_preview_file(path, "image")
    if not stat then
        util.write_plain_status(400, "Bad Request", err)
        return
    end

    local cache_path = util.thumbnail_cache_path(path, stat, util.read_preferences())
    local cache_stat = cache_path and nixio_fs.stat(cache_path) or nil
    if not cache_stat or cache_stat.type ~= "reg" then
        util.write_plain_status(404, "Not Found", "thumbnail not found")
        return
    end

    local fd = io.open(cache_path, "rb")
    if not fd then
        util.write_plain_status(500, "Internal Server Error", "open thumbnail failed")
        return
    end

    util.set_status(200, "OK")
    luci.http.header("Content-Length", tostring(cache_stat.size or 0))
    luci.http.header("Cache-Control", "private, max-age=86400")
    luci.http.header("X-Content-Type-Options", "nosniff")
    luci.http.prepare_content("image/jpeg")

    while true do
        local data = fd:read(65536)
        if not data or #data == 0 then
            break
        end
        luci.http.write(data)
    end
    fd:close()
end

function M.api_pdf()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_preview_file(path, "pdf")
    if not stat then
        util.write_plain_status(400, "Bad Request", err)
        return
    end

    local fd = io.open(path, "rb")
    if not fd then
        util.write_plain_status(500, "Internal Server Error", "open file failed")
        return
    end

    util.set_status(200, "OK")
    luci.http.header("Content-Length", tostring(stat.size or 0))
    luci.http.header("Cache-Control", "private, max-age=60")
    luci.http.header("X-Content-Type-Options", "nosniff")
    luci.http.prepare_content(util.pdf_mime_map[util.get_ext(path)])

    while true do
        local data = fd:read(65536)
        if not data or #data == 0 then
            break
        end
        luci.http.write(data)
    end
    fd:close()
end

local function parse_range_header(value, file_size)
    local start_value
    local end_value
    if value then
        start_value, end_value = value:match("^bytes=(%d*)%-(%d*)$")
    end
    if start_value == nil then
        return nil, nil
    end

    local start_pos
    local end_pos
    if start_value == "" then
        local suffix = tonumber(end_value)
        if not suffix or suffix <= 0 then
            return nil, nil
        end
        start_pos = suffix >= file_size and 0 or file_size - suffix
        end_pos = file_size - 1
    else
        start_pos = tonumber(start_value)
        end_pos = end_value == "" and file_size - 1 or tonumber(end_value)
        if not start_pos or not end_pos or start_pos < 0 or end_pos < start_pos then
            return nil, nil
        end
        end_pos = math.min(end_pos, file_size - 1)
    end

    if start_pos >= file_size then
        return nil, nil
    end
    return start_pos, end_pos
end

local function get_request_range()
    local candidates = {}
    local range_value = luci.http.getenv("HTTP_RANGE")
    table.insert(candidates, "http_env=" .. util.clean_log_value(range_value))
    if range_value and range_value ~= "" then
        return range_value, "http_env", table.concat(candidates, " ")
    end
    range_value = luci.http.getenv("Range")
    table.insert(candidates, "http_header=" .. util.clean_log_value(range_value))
    if range_value and range_value ~= "" then
        return range_value, "http_header", table.concat(candidates, " ")
    end
    range_value = os.getenv("HTTP_RANGE")
    table.insert(candidates, "process_env=" .. util.clean_log_value(range_value))
    if range_value and range_value ~= "" then
        return range_value, "process_env", table.concat(candidates, " ")
    end
    range_value = os.getenv("Range")
    table.insert(candidates, "process_header=" .. util.clean_log_value(range_value))
    if range_value and range_value ~= "" then
        return range_value, "process_header", table.concat(candidates, " ")
    end
    range_value = luci.http.formvalue("range")
    table.insert(candidates, "query=" .. util.clean_log_value(range_value))
    if range_value and range_value ~= "" then
        return range_value, "query", table.concat(candidates, " ")
    end
    return "", "none", table.concat(candidates, " ")
end

local video_range_window = 16 * 1024 * 1024

local function build_video_range(file_size, range_value)
    if range_value == "" then
        return 0, file_size - 1, false
    end

    local start_pos, end_pos = parse_range_header(range_value, file_size)
    if start_pos == nil then
        return nil, nil, nil
    end
    if end_pos - start_pos + 1 > video_range_window then
        end_pos = start_pos + video_range_window - 1
    end
    return start_pos, end_pos, true
end

local function ru32(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function ru64(data, pos)
    return ru32(data, pos) * 4294967296 + ru32(data, pos + 4)
end

local function be32(value)
    local b4 = value % 256
    value = (value - b4) / 256
    local b3 = value % 256
    value = (value - b3) / 256
    local b2 = value % 256
    value = (value - b2) / 256
    return string.char(value % 256, b2, b3, b4)
end

local function be64(value)
    return be32(math.floor(value / 4294967296)) .. be32(value % 4294967296)
end

local mp4_container_boxes = { trak = true, mdia = true, minf = true, stbl = true }

local function patch_moov_offsets(moov_data, shift)
    local patches = {}
    local codecs = {}
    local total_entries = 0
    local function walk(pos, limit)
        while pos + 7 <= limit do
            local size = ru32(moov_data, pos)
            local btype = moov_data:sub(pos + 4, pos + 7)
            local hlen = 8
            if size == 1 then
                if pos + 15 > limit then
                    return false
                end
                size = ru64(moov_data, pos + 8)
                hlen = 16
            elseif size == 0 then
                size = limit - pos + 1
            end
            if size < hlen or pos + size - 1 > limit then
                return false
            end
            if btype == "cmov" then
                return false
            end
            if btype == "stco" or btype == "co64" then
                local width = btype == "stco" and 4 or 8
                local count_pos = pos + hlen + 4
                if count_pos + 3 > limit then
                    return false
                end
                local count = ru32(moov_data, count_pos)
                local entry_pos = count_pos + 4
                if entry_pos + count * width - 1 > pos + size - 1 then
                    return false
                end
                total_entries = total_entries + count
                if total_entries > 1048576 then
                    return false
                end
                local out = {}
                for i = 0, count - 1 do
                    local p = entry_pos + i * width
                    local value = (width == 4 and ru32(moov_data, p) or ru64(moov_data, p)) + shift
                    if width == 4 and value >= 4294967296 then
                        return false
                    end
                    out[i + 1] = width == 4 and be32(value) or be64(value)
                end
                table.insert(patches, { pos = entry_pos, len = count * width, data = table.concat(out) })
            elseif btype == "stsd" then
                if pos + hlen + 15 <= limit then
                    local fourcc = moov_data:sub(pos + hlen + 12, pos + hlen + 15):gsub("[^%w]", "?")
                    table.insert(codecs, fourcc)
                end
            elseif mp4_container_boxes[btype] then
                if not walk(pos + hlen, pos + size - 1) then
                    return false
                end
            end
            pos = pos + size
        end
        return true
    end
    local root_hlen = ru32(moov_data, 1) == 1 and 16 or 8
    if not walk(1 + root_hlen, #moov_data) or #patches == 0 then
        return nil, table.concat(codecs, ",")
    end
    table.sort(patches, function(a, b) return a.pos < b.pos end)
    local pieces = {}
    local last = 1
    for _, patch in ipairs(patches) do
        table.insert(pieces, moov_data:sub(last, patch.pos - 1))
        table.insert(pieces, patch.data)
        last = patch.pos + patch.len
    end
    table.insert(pieces, moov_data:sub(last))
    return table.concat(pieces), table.concat(codecs, ",")
end

local function build_faststart_plan(path, file_size)
    local ext = util.get_ext(path)
    if ext ~= "mp4" and ext ~= "m4v" and ext ~= "mov" then
        return nil, "skip ext=" .. tostring(ext)
    end
    local fd = io.open(path, "rb")
    if not fd then
        return nil, "skip open_failed"
    end
    local boxes = {}
    local offset = 0
    while offset + 8 <= file_size and #boxes < 32 do
        fd:seek("set", offset)
        local header = fd:read(8)
        if not header or #header < 8 then
            break
        end
        local size = ru32(header, 1)
        local btype = header:sub(5, 8)
        local hlen = 8
        if size == 1 then
            local ext8 = fd:read(8)
            if not ext8 or #ext8 < 8 then
                break
            end
            size = ru64(ext8, 1)
            hlen = 16
        elseif size == 0 then
            size = file_size - offset
        end
        if size < hlen then
            break
        end
        table.insert(boxes, { type = btype, offset = offset, size = size })
        offset = offset + size
    end
    local mdat_off, moov
    for _, box in ipairs(boxes) do
        if box.type == "mdat" and not mdat_off then
            mdat_off = box.offset
        end
        if box.type == "moov" and not moov then
            moov = box
        end
    end
    if not moov or not mdat_off or moov.offset < mdat_off then
        fd:close()
        return nil, "skip layout_ok"
    end
    if moov.size > 16 * 1024 * 1024 then
        fd:close()
        return nil, "skip moov_too_large size=" .. tostring(moov.size)
    end
    fd:seek("set", moov.offset)
    local moov_data = fd:read(moov.size)
    fd:close()
    if not moov_data or #moov_data ~= moov.size then
        return nil, "skip moov_read_failed"
    end
    local patched, codecs = patch_moov_offsets(moov_data, moov.size)
    if not patched then
        return nil, "skip patch_failed codecs=" .. tostring(codecs)
    end
    local segments = {
        { offset = 0, length = mdat_off },
        { data = patched },
        { offset = mdat_off, length = moov.offset - mdat_off }
    }
    local tail_start = moov.offset + moov.size
    if tail_start < file_size then
        table.insert(segments, { offset = tail_start, length = file_size - tail_start })
    end
    return segments, "applied moov_size=" .. tostring(moov.size) .. " mdat_off=" .. tostring(mdat_off) ..
        " codecs=" .. tostring(codecs)
end

local function stream_segments(path, segments, start_pos, total_length)
    local nixio = require "nixio"
    local fd = io.open(path, "rb")
    if not fd then
        return 0, nil, "open file failed", 0
    end
    local remain = total_length
    local skip = start_pos
    local sent = 0
    local first_write_ms
    local mem_floor_kb = 100 * 1024
    local check_step = 4 * 1024 * 1024
    local next_check = check_step
    local waited_ms = 0

    local function push(data)
        luci.http.write(data)
        if not first_write_ms then
            first_write_ms = util.video_now_ms()
        end
        sent = sent + #data
        remain = remain - #data
        if sent >= next_check then
            next_check = sent + check_step
            local mem_kb = util.get_available_memory_kb()
            if mem_kb and mem_kb < mem_floor_kb then
                local wait_start = util.video_now_ms()
                while mem_kb and mem_kb < mem_floor_kb do
                    nixio.nanosleep(0, 200 * 1000000)
                    if util.video_now_ms() - wait_start > 60000 then
                        return "low memory timeout mem_kb=" .. tostring(mem_kb)
                    end
                    mem_kb = util.get_available_memory_kb()
                end
                waited_ms = waited_ms + (util.video_now_ms() - wait_start)
            end
        end
        return nil
    end

    for _, seg in ipairs(segments) do
        if remain <= 0 then
            break
        end
        local seg_len = seg.data and #seg.data or seg.length
        if skip >= seg_len then
            skip = skip - seg_len
        elseif seg.data then
            local piece = seg.data:sub(skip + 1, skip + math.min(remain, seg_len - skip))
            skip = 0
            local err = push(piece)
            if err then
                fd:close()
                return sent, first_write_ms, err, waited_ms
            end
        else
            if not fd:seek("set", seg.offset + skip) then
                fd:close()
                return sent, first_write_ms, "seek file failed", waited_ms
            end
            local seg_remain = math.min(seg_len - skip, remain)
            skip = 0
            while seg_remain > 0 do
                local data = fd:read(math.min(seg_remain, 65536))
                if not data or #data == 0 then
                    fd:close()
                    return sent, first_write_ms, "unexpected end of file", waited_ms
                end
                seg_remain = seg_remain - #data
                local err = push(data)
                if err then
                    fd:close()
                    return sent, first_write_ms, err, waited_ms
                end
            end
        end
    end
    fd:close()
    if remain > 0 then
        return sent, first_write_ms, "unexpected end of file", waited_ms
    end
    return sent, first_write_ms, nil, waited_ms
end

function M.api_video_check()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_preview_file(path, "video")
    if not stat then
        util.write_json_status(400, "Bad Request", { code = 1, message = err or "invalid file" })
        return
    end
    local file_size = stat.size or 0
    local range_value = get_request_range()
    local range_supported = range_value ~= ""
    local tmp_available = util.get_directory_available_bytes("/tmp") or 0
    util.write_json({
        code = 0,
        message = "success",
        data = {
            range_supported = range_supported,
            tmp_available = tmp_available,
            file_size = file_size,
            playable = range_supported or tmp_available >= file_size
        }
    })
end

function M.api_video()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat, err = validate_preview_file(path, "video")
    if not stat then
        util.write_plain_status(400, "Bad Request", err)
        return
    end

    local file_size = stat.size or 0
    if file_size <= 0 then
        util.write_plain_status(404, "Not Found", "empty file")
        return
    end

    local range_value, range_source = get_request_range()
    if range_value == "" then
        local tmp_available = util.get_directory_available_bytes("/tmp") or 0
        if tmp_available < file_size then
            util.write_json_status(507, "Insufficient Storage", {
                code = 2,
                message = _("Web server does not support Range requests and available memory is too small to play this video")
            })
            return
        end
    end
    local start_pos, end_pos, partial = build_video_range(file_size, range_value)
    luci.http.header("X-FS-Range-Source", range_source)
    if start_pos == nil then
        util.set_status(416, "Range Not Satisfiable")
        luci.http.header("Content-Range", "bytes */" .. tostring(file_size))
        luci.http.prepare_content("text/plain")
        luci.http.write("invalid range")
        return
    end

    local fd = io.open(path, "rb")
    if not fd then
        util.write_plain_status(500, "Internal Server Error", "open file failed")
        return
    end
    fd:close()

    local content_length = end_pos - start_pos + 1
    util.set_status(partial and 206 or 200, partial and "Partial Content" or "OK")
    if partial then
        luci.http.header("Content-Range", string.format("bytes %d-%d/%d", start_pos, end_pos, file_size))
    end
    luci.http.header("X-FS-Range-Served", partial and string.format("%d-%d", start_pos, end_pos) or "full")
    luci.http.header("Accept-Ranges", "bytes")
    luci.http.header("Content-Length", tostring(content_length))
    luci.http.header("Cache-Control", "private, max-age=60")
    luci.http.prepare_content(util.video_mime_map[util.get_ext(path)])

    if luci.http.getenv("REQUEST_METHOD") ~= "HEAD" then
        local segments
        if range_value == "" then
            local plan_ok, plan_segments = pcall(build_faststart_plan, path, file_size)
            if plan_ok then
                segments = plan_segments
            end
        end
        if not segments then
            segments = { { offset = 0, length = file_size } }
        end
        stream_segments(path, segments, start_pos, content_length)
    end
end

local function find_upload_conflicts(target_dir, names)
    local nixio_fs = require "nixio.fs"
    local conflicts = {}
    local blocked = {}
    for _, name in ipairs(names) do
        local stat = nixio_fs.lstat(util.join_path(target_dir, name))
        if stat then
            if stat.type == "reg" then
                table.insert(conflicts, name)
            else
                table.insert(blocked, name)
            end
        end
    end
    return conflicts, blocked
end

function M.api_upload_check()
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "POST required" })
        return
    end

    local total_size = util.parse_size(luci.http.formvalue("total_size"))
    local names, names_err = util.parse_upload_names(luci.http.formvalue("names"))
    if total_size == nil or not names then
        util.write_json_status(400, "Bad Request", { code = 1, message = names_err or "invalid total size" })
        return
    end

    local target_dir, available, upload_safety_margin, dir_err = util.get_upload_directory(luci.http.formvalue("target_dir"))
    if not target_dir then
        util.write_json_status(403, "Forbidden", { code = 1, message = dir_err })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end

    upload_safety_margin = upload_safety_margin or 0
    local required = total_size + upload_safety_margin
    local conflicts, blocked = find_upload_conflicts(target_dir, names)
    util.write_json({
        code = 0,
        message = "success",
        data = {
            target_dir = target_dir,
            available_bytes = available,
            required_bytes = required,
            safety_margin = upload_safety_margin,
            enough_space = available >= required,
            space_message = available >= required and "" or util.insufficient_space_message,
            conflicts = conflicts,
            blocked_conflicts = blocked
        }
    })
end

local function parse_query_params()
	return {
		target_dir = luci.http.formvalue("target_dir", true),
		expected_size = luci.http.formvalue("expected_size", true),
		overwrite = luci.http.formvalue("overwrite", true)
	}
end

local function close_upload_file(state)
    if state.fd then
        state.fd:close()
        state.fd = nil
    end
end

local function cleanup_upload(state)
    local nixio_fs = require "nixio.fs"
    close_upload_file(state)
    if state.temp_path then
        nixio_fs.unlink(state.temp_path)
        state.temp_path = nil
    end
end

local function fail_upload(state, status, message)
    if not state.error then
        state.status = status
        state.error = message
    end
    cleanup_upload(state)
end

local function start_upload_file(state, meta)
    local nixio_fs = require "nixio.fs"
    if state.started then
        fail_upload(state, 400, "only one file is allowed per request")
        return false
    end

    if not meta or meta.name ~= "file" then
        fail_upload(state, 400, "invalid upload field")
        return false
    end

    local name = meta.file
    if not util.validate_upload_name(name) then
        fail_upload(state, 400, "invalid file name")
        return false
    end

    local final_path = util.join_path(state.target_dir, name)
    local existing = nixio_fs.lstat(final_path)
    if existing and (not state.overwrite or existing.type ~= "reg") then
        fail_upload(state, 409, "target already exists")
        return false
    end

    local token = tostring({}):gsub("[^%w]", "")
    local temp_path = util.join_path(state.target_dir, ".harbor-upload-" .. tostring(os.time()) .. "-" .. token)
    local fd = io.open(temp_path, "wb")
    if not fd then
        fail_upload(state, 500, "create temporary file failed")
        return false
    end

    state.started = true
    state.name = name
    state.final_path = final_path
    state.temp_path = temp_path
    state.fd = fd
    return true
end

local function finish_upload_file(state)
    local nixio_fs = require "nixio.fs"
    close_upload_file(state)
    if state.written ~= state.expected_size then
        fail_upload(state, 400, "uploaded file size does not match")
        return
    end

    local existing = nixio_fs.lstat(state.final_path)
    if existing and (not state.overwrite or existing.type ~= "reg") then
        fail_upload(state, 409, "target already exists")
        return
    end

    if not os.rename(state.temp_path, state.final_path) then
        fail_upload(state, 500, "save uploaded file failed")
        return
    end
    state.temp_path = nil
    state.completed = true
end

local function handle_upload_chunk(state, meta, chunk, eof)
    if state.error then
        return
    end
    if not state.started and not start_upload_file(state, meta) then
        return
    end

    if chunk and #chunk > 0 then
        if state.written + #chunk > state.expected_size then
            fail_upload(state, 400, "uploaded file is larger than declared size")
            return
        end
        local write_ok, result = pcall(state.fd.write, state.fd, chunk)
        if not write_ok or not result then
            fail_upload(state, 500, "write uploaded file failed")
            return
        end
        state.written = state.written + #chunk
    end

    if eof then
        finish_upload_file(state)
    end
end

function M.api_upload()
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "POST required" })
        return
    end

    local params = parse_query_params()
    local expected_size = util.parse_size(params.expected_size)
    local target_dir, available, upload_safety_margin, dir_err = util.get_upload_directory(params.target_dir)
    if expected_size == nil or not target_dir then
        local status = target_dir and 400 or 403
        util.write_json_status(status, status == 400 and "Bad Request" or "Forbidden", {
            code = 1,
            message = dir_err or "invalid expected size"
        })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(target_dir) then
        return util.deny_system_operation()
    end
    upload_safety_margin = upload_safety_margin or 0
    if available < expected_size + upload_safety_margin then
        util.write_json_status(507, "Insufficient Storage", {
            code = 2,
            message = util.insufficient_space_message,
            data = {
                available_bytes = available,
                required_bytes = expected_size + upload_safety_margin
            }
        })
        return
    end

    local state = {
        target_dir = target_dir,
        expected_size = expected_size,
        overwrite = params.overwrite == "1",
        written = 0,
        status = 500
    }
    luci.http.setfilehandler(function(meta, chunk, eof)
        handle_upload_chunk(state, meta, chunk, eof)
    end)

    local parse_ok = pcall(function()
        luci.http.formvalue("file")
    end)
    if not parse_ok and not state.error then
        fail_upload(state, 400, "parse upload request failed")
    elseif not state.started and not state.error then
        fail_upload(state, 400, "upload file is missing")
    elseif not state.completed and not state.error then
        fail_upload(state, 400, "upload is incomplete")
    end

    if state.error then
        util.write_json_status(state.status, state.status == 409 and "Conflict" or "Upload Failed", {
            code = 1,
            message = state.error
        })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = {
            name = state.name,
            path = state.final_path,
            size = state.written
        }
    })
end

function M.api_chmod()
    if not util.validate_write_request() then
        return
    end
    local path = util.normalize_path(luci.http.formvalue("path"))
    local mode_str = luci.http.formvalue("mode")

    local mode_valid = mode_str and (#mode_str == 3 or #mode_str == 4) and mode_str:match("^[0-7]+$")

    if not path or not mode_valid then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid path or mode" })
        return
    end
    local nixio_fs = require "nixio.fs"
    local stat = nixio_fs.lstat(path)
    if not stat then
        util.write_json_status(404, "Not Found", { code = 1, message = "path not found" })
        return
    end
    if not util.system_operations_allowed() and util.is_system_path(path) then
        return util.deny_system_operation()
    end
    local mode = tonumber(mode_str, 8)
    if not mode then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid mode number" })
        return
    end

    local quoted_path = "'" .. path:gsub("'", "'\\''") .. "'"
    local cmd = "chmod " .. mode_str .. " " .. quoted_path .. " 2>/dev/null"
    local result = os.execute(cmd)
    if result ~= 0 then
        util.write_json_status(500, "Chmod Failed", { code = 1, message = "change permissions failed" })
        return
    end
    util.write_json({ code = 0, message = "success", data = { path = path, mode = mode_str } })
end

function M.api_batch_check()
    if not util.validate_write_request() then
        return
    end
    local action = luci.http.formvalue("action")
    local sources_json = luci.http.formvalue("sources")
    local target_dir = luci.http.formvalue("target_dir")
    if not action or not sources_json or not target_dir then
        util.write_json_status(400, "Bad Request", { code = 1, message = "missing parameters" })
        return
    end
    local jsonc = require "luci.jsonc"
    local ok, sources = pcall(jsonc.parse, sources_json)
    if not ok or type(sources) ~= "table" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid sources" })
        return
    end
    local nixio_fs = require "nixio.fs"
    local conflicts = {}
    for _, src in ipairs(sources) do
        local name = src:match("([^/]+)$")
        if name then
            local target = target_dir .. "/" .. name
            if nixio_fs.lstat(target) then
                table.insert(conflicts, { name = name, source = src, target = target })
            end
        end
    end
    util.write_json({ code = 0, message = "success", data = { conflicts = conflicts } })
end

-- Sniff a file's content to decide text vs binary for unknown extensions.
-- Strategy: a NUL byte means binary; otherwise validate the sample as UTF-8.
-- Valid UTF-8 => text (this also handles CJK, which the old printable-ratio
-- heuristic wrongly classified as binary). Files up to 1 MiB are validated in
-- full; larger files are sampled on the first 1 MiB, which is enough to tell
-- text from binary in practice.
local text_sniff_limit = 1048576

local function detect_file_content_type(path)
    local nixio_fs = require "nixio.fs"
    local stat = nixio_fs.stat(path)
    if not stat or stat.type ~= "reg" then
        return nil
    end
    if (stat.size or 0) == 0 then
        return "text"
    end

    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local sample = fd:read(text_sniff_limit) or ""
    fd:close()

    if sample:find("\0", 1, true) then
        return "binary"
    end
    if util.utf8_valid(sample) then
        return "text"
    end
    return "binary"
end

function M.api_detect_type()
    local path = util.normalize_path(luci.http.formvalue("path"))
    local nixio_fs = require "nixio.fs"
    local stat = path and nixio_fs.stat(path) or nil

    if not path or not stat or stat.type ~= "reg" then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Invalid file") })
        return
    end

    local detected = detect_file_content_type(path)
    if not detected then
        detected = (stat.size == 0) and "text" or "binary"
    end

    local response = {
        type = detected,
        size = stat.size,
        mtime = stat.mtime,
        path = path
    }

    util.write_json({ code = 0, data = response })
end

return M
