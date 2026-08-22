-- HarborFile terminal + tool install + background tasks api handlers
local unpack = table.unpack or unpack
local _ = require("luci.i18n").translate
local util = require "luci.controller.harbor_file.util"
local M = {}

function M.api_terminal_info()
    local info = util.read_ttyd_info()
    util.write_json({
        code = 0,
        message = "success",
        data = info
    })
end

function M.api_package_install_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    local current = util.read_package_install_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.write_json_status(409, "Conflict", {
            code = 1,
            message = _("Another package installation is already running"),
            data = util.build_package_install_response(current)
        })
        return
    end

    local path, package_type, err = util.validate_package_file(luci.http.formvalue("path"))
    if not path then
        util.write_json_status(400, "Bad Request", { code = 1, message = err })
        return
    end

    local executable, _, cmd_err = util.build_package_install_command({
        installer = util.package_ext_map[package_type].installer,
        package_type = package_type,
        path = path
    })
    if not executable then
        util.write_json_status(500, "Install Failed", { code = 1, message = cmd_err })
        return
    end

    local task = util.create_package_install_task(path, package_type)
    util.hb_log(util.package_install_log_file, "==== Package install request ====")
    if not util.write_package_install_state(task) then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Package installation failed") })
        return
    end

    local pid, start_err = util.start_package_install_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Package installation failed")
        task.exit_code = -1
        task.finished_at = util.current_timestamp()
        util.write_package_install_state(task)
        util.write_json_status(500, "Install Failed", { code = 1, message = start_err or _("Package installation failed") })
        return
    end

    task.pid = pid
    util.write_json({
        code = 0,
        message = "success",
        data = util.build_package_install_response(task)
    })
end

function M.api_package_install_status()
    local task_id = luci.http.formvalue("task_id")
    if type(task_id) ~= "string" or task_id == "" then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Invalid task id") })
        return
    end

    local task = util.read_package_install_state()
    if not task or task.task_id ~= task_id then
        util.write_json_status(404, "Not Found", { code = 1, message = _("Package install task not found") })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = util.build_package_install_response(task)
    })
end

function M.api_nginx_install_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    if util.detect_web_server() == "nginx" then
        util.write_json({
            code = 0,
            message = "success",
            data = {
                done = true,
                success = true,
                web_server = "nginx"
            }
        })
        return
    end

    local current = util.read_package_install_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.write_json_status(409, "Conflict", {
            code = 1,
            message = _("Another package installation is already running"),
            data = util.build_package_install_response(current)
        })
        return
    end

    local installer = util.detect_nginx_installer()
    if not installer then
        util.write_json_status(500, "Install Failed", {
            code = 1,
            message = _("Installer command not found")
        })
        return
    end

    local task = util.create_repository_install_task(util.nginx_package_name, installer)
    task.activate_nginx = true
    util.hb_log(util.package_install_log_file, "==== Nginx install request ====")
    if not util.write_package_install_state(task) then
        util.write_json_status(500, "Install Failed", {
            code = 1,
            message = _("Package installation failed")
        })
        return
    end

    local pid, start_err = util.start_package_install_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Package installation failed")
        task.exit_code = -1
        task.finished_at = util.current_timestamp()
        util.write_package_install_state(task)
        util.write_json_status(500, "Install Failed", {
            code = 1,
            message = start_err or _("Package installation failed")
        })
        return
    end

    task.pid = pid
    util.write_json({
        code = 0,
        message = "success",
        data = util.build_package_install_response(task)
    })
end

function M.api_thumbnail_generate_start()
    local nixio_fs = require "nixio.fs"
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "POST required" })
        return
    end

    local uname_fd = io.popen("uname -m")
    if uname_fd then
        local arch = uname_fd:read("*l") or ""
        uname_fd:close()
        if arch:lower():find("mips") then
            util.write_json_status(501, "Not Supported", {
                code = 4,
                message = _("This device does not support thumbnail generation"),
                data = { arch = arch }
            })
            return
        end
    end

    local current = util.read_thumbnail_task_state()
    if current and not current.done then
        util.write_json_status(409, "Conflict", {
            code = 1,
            message = _("Another thumbnail generation task is already running"),
            data = util.build_thumbnail_task_response(current)
        })
        return
    end

    local gm_path = util.find_executable("gm")
    if not gm_path then
        util.write_json_status(424, "Dependency Required", {
            code = 2,
            message = _("GraphicsMagick command not found"),
            data = {
                missing_tool = "gm",
                package_name = "graphicsmagick",
                installer = util.detect_package_installer()
            }
        })
        return
    end

    local mem_kb = util.get_available_memory_kb()
    if mem_kb and mem_kb < util.thumbnail_memory_margin then
        util.write_json_status(507, "Insufficient Memory", {
            code = 3,
            message = _("Insufficient memory for thumbnail generation"),
            data = { available_kb = mem_kb, required_kb = util.thumbnail_memory_margin }
        })
        return
    end

    local path = util.normalize_path(luci.http.formvalue("path"))
    local stat = path and nixio_fs.stat(path) or nil
    if not path or not stat or stat.type ~= "dir" then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid directory" })
        return
    end

    local preferences = util.read_preferences()
    local images, err = util.collect_thumbnail_images(path, preferences.show_hidden_files)
    if not images then
        util.write_json_status(400, "Bad Request", { code = 1, message = err or "read directory failed" })
        return
    end
    if #images == 0 then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("No image files found") })
        return
    end

    local cache_dir = util.thumbnail_cache_dir(preferences)
    if not cache_dir or not util.mkdir_p(cache_dir) or not nixio_fs.access(cache_dir, "w") then
        util.write_json_status(403, "Forbidden", { code = 1, message = _("Thumbnail cache directory is not writable") })
        return
    end

    local task = util.create_thumbnail_task(path, preferences, #images)
    util.hb_log(util.thumbnail_task_log_file, "==== Thumbnail task start ====")
    if not util.write_thumbnail_task_state(task) then
        util.write_json_status(500, "Thumbnail Failed", { code = 1, message = _("Thumbnail generation failed") })
        return
    end

    local pid, fork_err = util.start_thumbnail_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Thumbnail generation failed")
        task.finished_at = util.current_timestamp()
        util.hb_log(util.thumbnail_task_log_file, "fork failed: " .. tostring(fork_err))
        util.write_thumbnail_task_state(task)
        util.write_json_status(500, "Thumbnail Failed", { code = 1, message = task.message })
        return
    end

    util.write_json({ code = 0, message = "success", data = util.build_thumbnail_task_response(task) })
end

function M.api_thumbnail_tool_install_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    if util.find_executable("gm") then
        local task = util.create_repository_install_task("graphicsmagick", util.detect_package_installer() or "")
        task.state = "success"
        task.done = true
        task.success = true
        task.message = _("GraphicsMagick is already installed")
        task.exit_code = 0
        task.finished_at = util.current_timestamp()
        util.hb_log(util.package_install_log_file, "GraphicsMagick is already installed")
        util.write_package_install_state(task)
        util.write_json({ code = 0, message = "success", data = util.build_package_install_response(task) })
        return
    end

    local current = util.read_package_install_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.write_json_status(409, "Conflict", {
            code = 1,
            message = _("Another package installation is already running"),
            data = util.build_package_install_response(current)
        })
        return
    end

    local installer = util.detect_package_installer()
    if not installer then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Installer command not found") })
        return
    end

    local task = util.create_repository_install_task("graphicsmagick", installer)
    util.hb_log(util.package_install_log_file, "==== GraphicsMagick install request ====")
    if not util.write_package_install_state(task) then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Package installation failed") })
        return
    end

    local pid, start_err = util.start_package_install_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Package installation failed")
        task.exit_code = -1
        task.finished_at = util.current_timestamp()
        util.write_package_install_state(task)
        util.write_json_status(500, "Install Failed", { code = 1, message = start_err or _("Package installation failed") })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = util.build_package_install_response(task)
    })
end

function M.api_terminal_tool_install_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    if util.find_executable("ttyd") then
        local task = util.create_repository_install_task(util.terminal_package_name, util.detect_package_installer() or "")
        task.state = "success"
        task.done = true
        task.success = true
        task.message = _("ttyd is already installed")
        task.exit_code = 0
        task.finished_at = util.current_timestamp()
        util.hb_log(util.package_install_log_file, "ttyd is already installed")
        util.write_package_install_state(task)
        util.write_json({ code = 0, message = "success", data = util.build_package_install_response(task) })
        return
    end

    local current = util.read_package_install_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.write_json_status(409, "Conflict", {
            code = 1,
            message = _("Another package installation is already running"),
            data = util.build_package_install_response(current)
        })
        return
    end

    local installer = util.detect_package_installer()
    if not installer then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Installer command not found") })
        return
    end

    local task = util.create_repository_install_task(util.terminal_package_name, installer)
    util.hb_log(util.package_install_log_file, "==== ttyd install request ====")
    if not util.write_package_install_state(task) then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Package installation failed") })
        return
    end

    local pid, start_err = util.start_package_install_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Package installation failed")
        task.exit_code = -1
        task.finished_at = util.current_timestamp()
        util.write_package_install_state(task)
        util.write_json_status(500, "Install Failed", { code = 1, message = start_err or _("Package installation failed") })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = util.build_package_install_response(task)
    })
end

-- Generic one-click install for archive tools (zip/unzip/tar/gzip). Mirrors
-- the GraphicsMagick / ttyd install flow so a missing tool shows an install
-- button instead of just a hint.
function M.api_tool_install_start()
    local nixio_fs = require "nixio.fs"
    if not util.validate_write_request() then
        return
    end

    local tool = tostring(luci.http.formvalue("tool") or ""):lower()
    local package_name = util.tool_package_name(tool)
    if not package_name then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Unknown tool") })
        return
    end

    if util.find_executable(tool) then
        local task = util.create_repository_install_task(package_name, util.detect_package_installer() or "")
        task.state = "success"
        task.done = true
        task.success = true
        task.message = _("Tool is already installed")
        task.exit_code = 0
        task.finished_at = util.current_timestamp()
        util.hb_log(util.package_install_log_file, package_name .. " is already installed")
        util.write_package_install_state(task)
        util.write_json({ code = 0, message = "success", data = util.build_package_install_response(task) })
        return
    end

    local current = util.read_package_install_state()
    if current and (current.state == "pending" or current.state == "running") and not current.done then
        util.write_json_status(409, "Conflict", {
            code = 1,
            message = _("Another package installation is already running"),
            data = util.build_package_install_response(current)
        })
        return
    end

    local installer = util.detect_package_installer()
    if not installer then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Installer command not found") })
        return
    end

    local task = util.create_repository_install_task(package_name, installer)
    util.hb_log(util.package_install_log_file, "==== " .. package_name .. " install request ====")
    if not util.write_package_install_state(task) then
        util.write_json_status(500, "Install Failed", { code = 1, message = _("Package installation failed") })
        return
    end

    local pid, start_err = util.start_package_install_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Package installation failed")
        task.exit_code = -1
        task.finished_at = util.current_timestamp()
        util.write_package_install_state(task)
        util.write_json_status(500, "Install Failed", { code = 1, message = start_err or _("Package installation failed") })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = util.build_package_install_response(task)
    })
end

function M.api_thumbnail_generate_status()
    local task_id = luci.http.formvalue("task_id")
    if type(task_id) ~= "string" or task_id == "" then
        util.write_json_status(400, "Bad Request", { code = 1, message = _("Invalid task id") })
        return
    end

    local task = util.read_thumbnail_task_state()
    if not task or task.task_id ~= task_id then
        util.write_json_status(404, "Not Found", { code = 1, message = _("Thumbnail task not found") })
        return
    end

    util.write_json({
        code = 0,
        message = "success",
        data = util.build_thumbnail_task_response(task)
    })
end

return M
