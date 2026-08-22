-- HarborFile preferences api handlers
local unpack = table.unpack or unpack
local _ = require("luci.i18n").translate
local util = require "luci.controller.harbor_file.util"
local M = {}

function M.api_preferences()
    local preferences = util.read_preferences()
    if util.harbor_debug_log then
        util.preference_log("api_preferences start")
        util.preference_log("base view_mode=" .. tostring(preferences.view_mode) ..
            " home_dir=" .. tostring(preferences.home_dir) ..
            " allow_system_operations=" .. tostring(preferences.allow_system_operations) ..
            " show_hidden_files=" .. tostring(preferences.show_hidden_files) ..
            " enable_thumbnails=" .. tostring(preferences.enable_thumbnails))
    end
    local nginx_preferences = util.read_nginx_preferences()
    if util.harbor_debug_log then
        util.preference_log("nginx template=" .. tostring(util.nginx_template_file) ..
            " available=" .. tostring(nginx_preferences.nginx_config_available) ..
            " uwsgi_request_buffering=" .. tostring(nginx_preferences.uwsgi_request_buffering) ..
            " client_max_body_size=" .. tostring(nginx_preferences.client_max_body_size))
    end
    for key, value in pairs(nginx_preferences) do
        preferences[key] = value
    end
    local uwsgi_preferences = util.read_uwsgi_preferences()
    if util.harbor_debug_log then
        util.preference_log("uwsgi config=" .. tostring(util.uwsgi_config_file) ..
            " available=" .. tostring(uwsgi_preferences.uwsgi_config_available) ..
            " reload-on-as=" .. tostring(uwsgi_preferences["reload-on-as"]) ..
            " reload-on-as_enabled=" .. tostring(uwsgi_preferences["reload-on-as_enabled"]) ..
            " reload-on-rss=" .. tostring(uwsgi_preferences["reload-on-rss"]) ..
            " reload-on-rss_enabled=" .. tostring(uwsgi_preferences["reload-on-rss_enabled"]) ..
            " post-buffering=" .. tostring(uwsgi_preferences["post-buffering"]) ..
            " limit-as=" .. tostring(uwsgi_preferences["limit-as"]) ..
            " reload-mercy=" .. tostring(uwsgi_preferences["reload-mercy"]) ..
            " buffer-size=" .. tostring(uwsgi_preferences["buffer-size"]))
    end
    for key, value in pairs(uwsgi_preferences) do
        preferences[key] = value
    end
    local uhttpd_preferences = util.read_uhttpd_preferences()
    if util.harbor_debug_log then
        util.preference_log("uhttpd config available=" .. tostring(uhttpd_preferences.uhttpd_config_available) ..
            " script_timeout=" .. tostring(uhttpd_preferences.uhttpd_script_timeout) ..
            " network_timeout=" .. tostring(uhttpd_preferences.uhttpd_network_timeout))
    end
    for key, value in pairs(uhttpd_preferences) do
        preferences[key] = value
    end
    preferences.web_server = util.detect_web_server()
    preferences.nginx_running = preferences.web_server == "nginx"
    preferences.fcm = util.is_fanchmwrt_system()
    if util.harbor_debug_log then
        util.preference_log("detected web_server=" .. tostring(preferences.web_server) ..
            " nginx_running=" .. tostring(preferences.nginx_running) ..
            " fcm=" .. tostring(preferences.fcm))
        util.preference_log("response nginx_config_available=" .. tostring(preferences.nginx_config_available) ..
            " uwsgi_request_buffering=" .. tostring(preferences.uwsgi_request_buffering) ..
            " client_max_body_size=" .. tostring(preferences.client_max_body_size) ..
            " uwsgi_config_available=" .. tostring(preferences.uwsgi_config_available) ..
            " uhttpd_config_available=" .. tostring(preferences.uhttpd_config_available))
    end
    util.write_json({
        code = 0,
        message = "success",
        data = preferences
    })
end

function M.api_save_show_line_numbers()
    if not util.validate_write_request() then
        return
    end
    local value = luci.http.formvalue("value") == "1" and 1 or 0
    if not util.save_show_line_numbers(value) then
        util.write_json_status(500, "Save Failed", { code = 1, message = "save show_line_numbers failed" })
        return
    end
    util.write_json({ code = 0, message = "success", data = { show_line_numbers = value } })
end

function M.api_save_last_directory()
    if not util.validate_write_request() then
        return
    end
    local path = luci.http.formvalue("path")
    if not util.save_last_directory(path) then
        util.write_json_status(400, "Bad Request", { code = 1, message = "invalid path" })
        return
    end
    util.write_json({ code = 0, message = "success", data = { last_directory = path } })
end

function M.api_save_preferences()
    if not util.validate_write_request() then
        return
    end

    local section = luci.http.formvalue("section") or "basic"
    local current = util.read_preferences()
    local web_server = util.detect_web_server()

    if section == "nginx" then
        section = "web_server"
    end

    if section == "window" then
        local window_target = luci.http.formvalue("window_target") == "mobile" and "mobile" or "desktop"
        local current_width = window_target == "mobile" and current.mobile_window_width or current.window_width
        local current_height = window_target == "mobile" and current.mobile_window_height or current.window_height
        local window_width = util.normalize_window_dimension(
            luci.http.formvalue("window_width"),
            current_width or util.preference_defaults.window_width,
            180,
            4096
        )
        local window_height = util.normalize_window_dimension(
            luci.http.formvalue("window_height"),
            current_height or util.preference_defaults.window_height,
            130,
            4096
        )
        if not util.save_window_preferences(window_width, window_height, window_target) then
            util.write_json_status(500, "Save Failed", { code = 1, message = "save window preferences failed" })
            return
        end
        local saved = util.read_preferences()
        util.write_json({ code = 0, message = "success", data = saved })
        return
    end

    if section == "web_server" then
        if web_server == "uhttpd" then
            local current_uhttpd_preferences = util.read_uhttpd_preferences()
            local uhttpd_preferences = util.read_uhttpd_form_preferences(current_uhttpd_preferences)
            local uhttpd_ok, uhttpd_saved, uhttpd_err = pcall(util.save_uhttpd_configuration, uhttpd_preferences)
            if not uhttpd_ok then
                uhttpd_err = tostring(uhttpd_saved)
                uhttpd_saved = nil
            end
            if not uhttpd_saved then
                util.write_json({
                    code = 1,
                    message = uhttpd_err or _("Failed to update uHTTPd configuration")
                })
                return
            end

            local preferences = util.read_preferences()
            local nginx_preferences = util.read_nginx_preferences()
            for key, value in pairs(nginx_preferences) do
                preferences[key] = value
            end
            local uwsgi_preferences = util.read_uwsgi_preferences()
            for key, value in pairs(uwsgi_preferences) do
                preferences[key] = value
            end
            local saved_uhttpd_preferences = util.read_uhttpd_preferences()
            for key, value in pairs(saved_uhttpd_preferences) do
                preferences[key] = value
            end
            preferences.web_server = web_server
            preferences.nginx_running = false
            preferences.fcm = util.is_fanchmwrt_system()
            util.write_json({
                code = 0,
                message = "success",
                data = preferences
            })
            return
        end

        if web_server ~= "nginx" then
            util.write_json_status(400, "Web Service Not Supported", {
                code = 1,
                message = _("Web service is not supported")
            })
            return
        end

        local current_nginx_preferences = util.read_nginx_preferences()
        local nginx_preferences = util.read_nginx_form_preferences(current_nginx_preferences)
        local current_uwsgi_preferences = util.read_uwsgi_preferences()
        local uwsgi_preferences = util.read_uwsgi_form_preferences(current_uwsgi_preferences)

        if not current_nginx_preferences.nginx_config_available then
            util.write_json({
                code = 1,
                message = _("Nginx configuration template was not found")
            })
            return
        end
        if not current_uwsgi_preferences.uwsgi_config_available then
            util.write_json({
                code = 1,
                message = _("uWSGI configuration file was not found")
            })
            return
        end

        local ok, applied, apply_err = pcall(util.save_nginx_configuration, nginx_preferences)
        if not ok then
            apply_err = tostring(applied)
            applied = nil
        end
        if not applied then
            util.write_json({
                code = 1,
                message = apply_err or _("Failed to update Nginx configuration")
            })
            return
        end

        local uwsgi_ok, uwsgi_saved, uwsgi_err = pcall(util.save_uwsgi_configuration, uwsgi_preferences)
        if not uwsgi_ok then
            uwsgi_err = tostring(uwsgi_saved)
            uwsgi_saved = nil
        end
        if not uwsgi_saved then
            util.write_json({
                code = 1,
                message = uwsgi_err or _("Failed to update uWSGI configuration")
            })
            return
        end

        local preferences = util.read_preferences()
        local saved_nginx_preferences = util.read_nginx_preferences()
        for key, value in pairs(saved_nginx_preferences) do
            preferences[key] = value
        end
        local saved_uwsgi_preferences = util.read_uwsgi_preferences()
        for key, value in pairs(saved_uwsgi_preferences) do
            preferences[key] = value
        end
        local uhttpd_preferences = util.read_uhttpd_preferences()
        for key, value in pairs(uhttpd_preferences) do
            preferences[key] = value
        end
        preferences.web_server = web_server
        preferences.nginx_running = true
        preferences.fcm = util.is_fanchmwrt_system()
        util.write_json({
            code = 0,
            message = "success",
            data = preferences
        })
        return
    end

    if section ~= "basic" then
        util.write_json_status(400, "Invalid Section", { code = 1, message = "invalid section" })
        return
    end

    local view_mode = util.normalize_preference_number(
        luci.http.formvalue("view_mode"),
        current.view_mode,
        util.valid_view_mode_values
    )
    local allow_system_operations = util.normalize_preference_number(
        luci.http.formvalue("allow_system_operations"),
        current.allow_system_operations,
        util.valid_boolean_values
    )
    local show_hidden_files = util.normalize_preference_number(
        luci.http.formvalue("show_hidden_files"),
        current.show_hidden_files,
        util.valid_boolean_values
    )
    local enable_thumbnails = util.normalize_preference_number(
        luci.http.formvalue("enable_thumbnails"),
        current.enable_thumbnails,
        util.valid_boolean_values
    )
    local editor_auto_indent = util.normalize_preference_number(
        luci.http.formvalue("editor_auto_indent"),
        current.editor_auto_indent,
        util.valid_boolean_values
    )
    local editor_auto_wrap = util.normalize_preference_number(
        luci.http.formvalue("editor_auto_wrap"),
        current.editor_auto_wrap,
        util.valid_boolean_values
    )
    local restore_last_directory = util.normalize_preference_number(
        luci.http.formvalue("restore_last_directory"),
        current.restore_last_directory,
        util.valid_boolean_values
    )
    local home_dir = util.normalize_home_dir(luci.http.formvalue("home_dir") or current.home_dir)

    if not util.save_basic_preferences(
        view_mode,
        allow_system_operations,
        show_hidden_files,
        home_dir,
        enable_thumbnails,
        editor_auto_indent,
        editor_auto_wrap,
        restore_last_directory
    ) then
        util.write_json_status(500, "Save Failed", { code = 1, message = "save preferences failed" })
        return
    end
    util.build_quick_access({ home_dir = home_dir })

    local preferences = util.read_preferences()
    local nginx_preferences = util.read_nginx_preferences()
    for key, value in pairs(nginx_preferences) do
        preferences[key] = value
    end
    local uwsgi_preferences = util.read_uwsgi_preferences()
    for key, value in pairs(uwsgi_preferences) do
        preferences[key] = value
    end
    local uhttpd_preferences = util.read_uhttpd_preferences()
    for key, value in pairs(uhttpd_preferences) do
        preferences[key] = value
    end
    preferences.web_server = web_server
    preferences.nginx_running = web_server == "nginx"
    preferences.fcm = util.is_fanchmwrt_system()

    util.write_json({
        code = 0,
        message = "success",
        data = preferences
    })
end

return M
