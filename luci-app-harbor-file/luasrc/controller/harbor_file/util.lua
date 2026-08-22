-- HarborFile shared helpers + data (no api handlers).
local unpack = table.unpack or unpack
local _ = require("luci.i18n").translate
local M = {}
local common_directory_entries = {
    { name = "Documents", path_name = "documents", icon = "documents" },
    { name = "Pictures", path_name = "pictures", icon = "pictures" },
    { name = "Videos", path_name = "videos", icon = "videos" },
    { name = "Music", path_name = "music", icon = "music" },
    { name = "Downloads", path_name = "downloads", icon = "downloads" }
}

local hidden_mounts = {
    ["/rom"] = true,
    ["/overlay"] = true,
    ["/dev"] = true
}

local system_folder_roots = {
    "/bin",
    "/sbin",
    "/proc",
    "/dev",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/lib64",
    "/sys",
    "/lib64",
    "/overlay",
    "/rom"
}

local image_mime_map = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    bmp = "image/bmp",
    webp = "image/webp",
    svg = "image/svg+xml",
    ico = "image/x-icon",
    avif = "image/avif"
}

local text_ext_map = {
    txt = true,
    log = true,
    conf = true,
    cfg = true,
    ini = true,
    json = true,
    xml = true,
    csv = true,
    lua = true,
    sh = true,
    md = true,
    yaml = true,
    yml = true,
    html = true,
    htm = true,
    css = true,
    js = true
}

local video_mime_map = {
    mp4 = "video/mp4",
    webm = "video/webm",
    ogg = "video/ogg",
    ogv = "video/ogg",
    mov = "video/quicktime",
    m4v = "video/x-m4v",
    mkv = "video/x-matroska",
    avi = "video/x-msvideo"
}

local pdf_mime_map = {
    pdf = "application/pdf"
}

local package_ext_map = {
    ipk = {
        installer = "opkg",
        display_type = "IPK Package"
    },
    apk = {
        installer = "apk",
        display_type = "APK Package"
    }
}

local harbor_log_file = "/tmp/log/harbor_file.log"
local harbor_debug_log = os.getenv("HARBOR_FILE_DEBUG") == "1"

local archive = {
    state_file = "/tmp/harbor_file_archive_state.json",
    log_file = harbor_log_file,
    log_limit = 131072,
    create_formats = {
        ["tar.gz"] = { extension = ".tar.gz", command = "tar", title = "TAR.GZ" },
        tar = { extension = ".tar", command = "tar", title = "TAR" },
        zip = { extension = ".zip", command = "zip", title = "ZIP" }
    },
    extract_formats = {
        zip = { command = "unzip", title = "ZIP", container = true },
        tar = { command = "tar", title = "TAR", container = true },
        ["tar.gz"] = { command = "tar", title = "TAR.GZ", container = true },
        tgz = { command = "tar", title = "TGZ", container = true, canonical = "tar.gz" },
        gz = { command = "gzip", title = "GZ", single_file = true }
    }
}

local package_index_cache_roots = {
    opkg = {
        "/tmp/opkg-lists",
        "/var/opkg-lists"
    },
    apk = {
        "/var/cache/apk",
        "/etc/apk/cache",
        "/var/lib/apk"
    }
}

local opkg_required_feed_groups = {
    { "base" },
    { "luci" },
    { "packages" },
    { "routing", "routting" },
    { "telephony" }
}

-- File size is deliberately not capped for editors.  Requests are paged so a
-- large file does not need to be read into the UI in one response.
local default_binary_read_kb = 16
local max_binary_read_kb = 16
local max_binary_read_size = max_binary_read_kb * 1024
local operation_space_ratio = 0.05
local thumbnail_memory_margin = 20 * 1024
local insufficient_space_message = "available space is less than 5% of the current partition, operation is not allowed"
local package_install_state_file = "/tmp/harbor_file_package_install_state.json"
local package_install_log_file = harbor_log_file
local preferences_log_file = harbor_log_file
local package_install_log_limit = 131072
local thumbnail_task_state_file = "/tmp/harbor_file_thumbnail_state.json"
local thumbnail_task_log_file = harbor_log_file
local thumbnail_task_log_limit = 65536
local thumbnail_size = 128
local thumbnail_cache_version = "contain-v2"
local nginx_template_file = "/etc/nginx/uci.conf.template"
local nginx_insert_anchor = "large_client_header_buffers"
local nginx_package_name = "luci-nginx"
local terminal_package_name = "ttyd"

-- Maps a missing executable back to the repository package that provides it,
-- so the frontend can offer a one-click install (same pattern as
-- GraphicsMagick / ttyd).
local tool_package_map = {
    zip = "zip",
    unzip = "unzip",
    tar = "tar",
    gzip = "gzip"
}
local function tool_package_name(tool)
    return tool_package_map[tostring(tool or ""):lower()]
end
local uwsgi_config_file = "/etc/uwsgi/vassals/luci-webui.ini"
local uhttpd_script_timeout_default = 600
local uhttpd_network_timeout_default = 600
local uwsgi_configuration_options = {
    {
        name = "reload-on-as",
        preference = "reload-on-as",
        enabled_preference = "reload-on-as_enabled",
        default_value = 256,
        default_enabled = 0
    },
    {
        name = "reload-on-rss",
        preference = "reload-on-rss",
        enabled_preference = "reload-on-rss_enabled",
        default_value = 192,
        default_enabled = 0
    },
    {
        name = "post-buffering",
        preference = "post-buffering",
        default_value = 8192
    },
    {
        name = "limit-as",
        preference = "limit-as",
        default_value = 1000
    },
    {
        name = "reload-mercy",
        preference = "reload-mercy",
        default_value = 8
    },
    {
        name = "buffer-size",
        preference = "buffer-size",
        default_value = 10000
    }
}
local nginx_configuration_options = {
    {
        preference = "uwsgi_request_buffering",
        directive = "uwsgi_request_buffering",
        values = {
            [0] = "off",
            [1] = "on"
        }
    },
    {
        preference = "client_max_body_size",
        directive = "client_max_body_size",
        value = function(preference_value)
            if preference_value == 0 then
                return "0"
            end
            return tostring(preference_value) .. "M"
        end
    }
}
local preference_defaults = {
    view_mode = 1,
    allow_system_operations = 0,
    show_hidden_files = 0,
    home_dir = "/tmp/root",
    enable_thumbnails = 0,
    editor_auto_indent = 0,
    editor_auto_wrap = 0,
    restore_last_directory = 0,
    show_line_numbers = 0,
    last_directory = "",
    -- Shared default size for every desktop-style document window.  The
    -- browser saves a user resize back to these two UCI options.
    window_width = 820,
    window_height = 590,
    mobile_window_width = 360,
    mobile_window_height = 560
}
local valid_view_mode_values = {
    [0] = true,
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true
}
local valid_boolean_values = {
    [0] = true,
    [1] = true
}
local find_executable
local is_hidden_file_name

local function write_json(data)
    local jsonc = require "luci.jsonc"
    luci.http.prepare_content("application/json")
    luci.http.write(jsonc.stringify(data))
end

local function set_status(code, reason)
    if luci.http.status then
        luci.http.status(code, reason)
    else
        luci.http.header("Status", tostring(code) .. " " .. tostring(reason or ""))
    end
end

local function write_json_status(code, reason, data)
    set_status(code, reason)
    write_json(data)
end

local function write_plain_status(code, reason, message)
    set_status(code, reason)
    luci.http.prepare_content("text/plain")
    luci.http.write(message)
end

local function video_now_ms()
    local nixio = require "nixio"
    local seconds, microseconds = nixio.gettimeofday()
    return (tonumber(seconds) or 0) * 1000 + math.floor((tonumber(microseconds) or 0) / 1000)
end

local function clean_log_value(value)
    return tostring(value or ""):gsub("[%z\1-\31\127]", "?"):sub(1, 512)
end

local function current_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function read_json_file(path)
    local nixio_fs = require "nixio.fs"
    local jsonc = require "luci.jsonc"
    local content = nixio_fs.readfile(path)
    if not content or content == "" then
        return nil
    end
    local data = jsonc.parse(content)
    return type(data) == "table" and data or nil
end

local function write_json_file(path, data)
    local nixio_fs = require "nixio.fs"
    local jsonc = require "luci.jsonc"
    local content = jsonc.stringify(data)
    if not content then
        return false
    end
    return nixio_fs.writefile(path, content)
end

local function hb_log(log_path, message)
    local nixio_fs = require "nixio.fs"
    log_path = harbor_log_file
    if not nixio_fs.stat("/tmp/log") then
        nixio_fs.mkdir("/tmp/log")
    end
    local stat = nixio_fs.stat(log_path)
    if stat and (stat.size or 0) >= 262144 then
        nixio_fs.unlink(log_path .. ".1")
        os.rename(log_path, log_path .. ".1")
    end
    local fd = io.open(log_path, "a")
    if fd then
        fd:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), tostring(message or "")))
        fd:close()
    end
end

-- Truncate the shared task log so each archive / install / thumbnail task
-- starts with a clean window instead of an ever-growing history.
local function clear_log()
    local nixio_fs = require "nixio.fs"
    if not nixio_fs.stat("/tmp/log") then
        nixio_fs.mkdir("/tmp/log")
    end
    local fd = io.open(harbor_log_file, "w")
    if fd then
        fd:close()
    end
end

local function preference_log(message)
    if harbor_debug_log then
        hb_log(preferences_log_file, clean_log_value(message))
    end
end

local function truncate_log_text(content, limit)
    if not content or content == "" then
        return ""
    end
    if #content <= limit then
        return content
    end
    return "... truncated ...\n" .. content:sub(#content - limit + 1)
end

local function read_log_file(path, limit)
    local nixio_fs = require "nixio.fs"
    path = harbor_log_file
    return truncate_log_text(nixio_fs.readfile(path) or "", limit or package_install_log_limit)
end

local function shell_quote(value)
    local text = tostring(value or "")
    return "'" .. text:gsub("'", [['"'"']]) .. "'"
end

local function normalize_path(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
        return nil
    end

    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #parts == 0 then
                return nil
            end
            table.remove(parts)
        elseif segment ~= "." and segment ~= "" then
            table.insert(parts, segment)
        end
    end

    if #parts == 0 then
        return "/"
    end

    return "/" .. table.concat(parts, "/")
end

local function parent_path(path)
    if not path or path == "/" then
        return "/"
    end

    local parent = path:match("(.+)/[^/]+$")
    if not parent or parent == "" then
        return "/"
    end

    return parent
end

local function join_path(base, name)
    if base == "/" then
        return "/" .. name
    end
    return base .. "/" .. name
end

local function get_ext(name)
    local base_name = name and name:match("([^/]+)$") or nil
    local ext = base_name and base_name:match("%.([^.]+)$") or nil
    return ext and ext:lower() or ""
end

local function is_child_path(path, root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

-- Strict UTF-8 validator. Rejects overlong encodings (C0/C1), UTF-16
-- surrogates (ED A0..BF) and code points above U+10FFFF (F4 90..BF).
local function utf8_valid(data)
    local i = 1
    local n = #data
    while i <= n do
        local b = data:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            if i + 1 > n then return false end
            local b2 = data:byte(i + 1)
            if b2 < 0x80 or b2 > 0xBF then return false end
            i = i + 2
        elseif b == 0xE0 then
            if i + 2 > n then return false end
            local b2, b3 = data:byte(i + 1), data:byte(i + 2)
            if b2 < 0xA0 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
            i = i + 3
        elseif (b >= 0xE1 and b <= 0xEC) or (b >= 0xEE and b <= 0xEF) then
            if i + 2 > n then return false end
            local b2, b3 = data:byte(i + 1), data:byte(i + 2)
            if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
            i = i + 3
        elseif b == 0xED then
            if i + 2 > n then return false end
            local b2, b3 = data:byte(i + 1), data:byte(i + 2)
            if b2 < 0x80 or b2 > 0x9F or b3 < 0x80 or b3 > 0xBF then return false end
            i = i + 3
        elseif b == 0xF0 then
            if i + 3 > n then return false end
            local b2, b3, b4 = data:byte(i + 1), data:byte(i + 2), data:byte(i + 3)
            if b2 < 0x90 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
            i = i + 4
        elseif b >= 0xF1 and b <= 0xF3 then
            if i + 3 > n then return false end
            local b2, b3, b4 = data:byte(i + 1), data:byte(i + 2), data:byte(i + 3)
            if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
            i = i + 4
        elseif b == 0xF4 then
            if i + 3 > n then return false end
            local b2, b3, b4 = data:byte(i + 1), data:byte(i + 2), data:byte(i + 3)
            if b2 < 0x80 or b2 > 0x8F or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

local function normalize_preference_number(value, default_value, valid_values)
    local number = tonumber(value)
    if not number then
        return default_value
    end
    number = math.floor(number)
    if valid_values and not valid_values[number] then
        return default_value
    end
    return number
end

local function normalize_home_dir(value)
    local normalized = normalize_path(value)
    if not normalized then
        return preference_defaults.home_dir
    end
    return normalized
end

local function mkdir_p(path)
    local nixio_fs = require "nixio.fs"
    local normalized = normalize_path(path)
    if not normalized then
        return false
    end
    if normalized == "/" then
        return true
    end
    local existing = nixio_fs.stat(normalized)
    if existing then
        return existing.type == "dir"
    end

    local current = ""
    for part in normalized:gmatch("[^/]+") do
        current = current .. "/" .. part
        local stat = nixio_fs.stat(current)
        if stat then
            if stat.type ~= "dir" then
                return false
            end
        elseif not nixio_fs.mkdir(current) then
            return false
        end
    end
    return true
end

local function build_quick_access(preferences)
    local nixio_fs = require "nixio.fs"
    local i18n = require "luci.i18n"
    local home_dir = normalize_home_dir(preferences and preferences.home_dir)
    local quick_access = {}

    mkdir_p(home_dir)
    for _, item in ipairs(common_directory_entries) do
        local path = normalize_path(join_path(home_dir, item.path_name))
        if path then
            mkdir_p(path)
            table.insert(quick_access, {
                name = i18n.translate(item.name),
                path = path,
                icon = item.icon,
                exists = nixio_fs.stat(path) ~= nil
            })
        end
    end

    return quick_access
end

local function normalize_port_number(value, default_value)
    local number = tonumber(value)
    if not number then
        return default_value
    end
    number = math.floor(number)
    if number < 1 or number > 65535 then
        return default_value
    end
    return number
end

local function normalize_nginx_body_size(value, default_value)
    local number = tonumber(value)
    if not number then
        return default_value
    end
    number = math.floor(number)
    if number < 0 or number > 1024 then
        return default_value
    end
    return number
end

local function normalize_integer_value(value, default_value)
    local number = tonumber(value)
    if not number then
        return default_value
    end
    return math.floor(number)
end

local function normalize_window_dimension(value, default_value, minimum, maximum)
    local number = normalize_integer_value(value, default_value)
    minimum = minimum or 180
    maximum = maximum or 4096
    if number < minimum or number > maximum then
        return default_value
    end
    return number
end

local function normalize_timeout_value(value, default_value)
    local number = normalize_integer_value(value, default_value)
    if number < 0 then
        return default_value
    end
    return number
end

local function to_boolean(value)
    local text = tostring(value or ""):lower()
    return text == "1" or text == "true" or text == "yes" or text == "on"
end

local function ensure_preference_section(uci)
    uci = uci or require("luci.model.uci").cursor()
    if uci:get("harbor_file", "main") == nil then
        uci:section("harbor_file", "settings", "main", {})
    end
end

local function read_preference_value(option)
    local uci = require("luci.model.uci").cursor()
    local ok, value = pcall(function()
        return uci:get("harbor_file", "main", option)
    end)
    return ok and value or nil
end

local function detect_web_server()
    local process = io.popen("ps ww 2>/dev/null || ps w 2>/dev/null || ps 2>/dev/null", "r")
    if not process then
        return "unknown"
    end

    local nginx_running = false
    local uhttpd_running = false
    for line in process:lines() do
        local command = line:lower()
        if command:find("nginx:", 1, true) or command:find("/nginx", 1, true) or
                command:match("%snginx%s") then
            nginx_running = true
        elseif command:find("/uhttpd", 1, true) or command:match("%suhttpd%s") then
            uhttpd_running = true
        end
    end
    process:close()

    if nginx_running then
        return "nginx"
    end
    if uhttpd_running then
        return "uhttpd"
    end
    return "unknown"
end

local function is_fanchmwrt_system()
    local nixio_fs = require "nixio.fs"
    return nixio_fs.access("/etc/fwx_release") and 1 or 0
end

local function read_preferences()
    return {
        view_mode = normalize_preference_number(
            read_preference_value("view_mode"),
            preference_defaults.view_mode,
            valid_view_mode_values
        ),
        allow_system_operations = normalize_preference_number(
            read_preference_value("allow_system_operations"),
            preference_defaults.allow_system_operations,
            valid_boolean_values
        ),
        show_hidden_files = normalize_preference_number(
            read_preference_value("show_hidden_files"),
            preference_defaults.show_hidden_files,
            valid_boolean_values
        ),
        home_dir = normalize_home_dir(read_preference_value("home_dir")),
        enable_thumbnails = normalize_preference_number(
            read_preference_value("enable_thumbnails"),
            preference_defaults.enable_thumbnails,
            valid_boolean_values
        ),
        editor_auto_indent = normalize_preference_number(
            read_preference_value("editor_auto_indent"),
            preference_defaults.editor_auto_indent,
            valid_boolean_values
        ),
        editor_auto_wrap = normalize_preference_number(
            read_preference_value("editor_auto_wrap"),
            preference_defaults.editor_auto_wrap,
            valid_boolean_values
        ),
        restore_last_directory = normalize_preference_number(
            read_preference_value("restore_last_directory"),
            preference_defaults.restore_last_directory,
            valid_boolean_values
        ),
        show_line_numbers = normalize_preference_number(
            read_preference_value("show_line_numbers"),
            preference_defaults.show_line_numbers,
            valid_boolean_values
        ),
        last_directory = tostring(read_preference_value("last_directory") or ""),
        window_width = normalize_window_dimension(
            read_preference_value("window_width"),
            preference_defaults.window_width,
            180,
            4096
        ),
        window_height = normalize_window_dimension(
            read_preference_value("window_height"),
            preference_defaults.window_height,
            130,
            4096
        ),
        mobile_window_width = normalize_window_dimension(
            read_preference_value("mobile_window_width"),
            preference_defaults.mobile_window_width,
            180,
            4096
        ),
        mobile_window_height = normalize_window_dimension(
            read_preference_value("mobile_window_height"),
            preference_defaults.mobile_window_height,
            130,
            4096
        )
    }
end

local function read_uwsgi_preferences(include_state)
    local nixio_fs = require "nixio.fs"
    local content = nixio_fs.readfile(uwsgi_config_file)
    local preferences = {
        uwsgi_config_available = content ~= nil
    }
    if include_state then
        preferences._present = {}
    end

    for _, option in ipairs(uwsgi_configuration_options) do
        preferences[option.preference] = option.default_value
        if option.enabled_preference then
            preferences[option.enabled_preference] = option.default_enabled
        end
    end

    if not content then
        return preferences
    end

    for line in content:gmatch("[^\r\n]+") do
        for _, option in ipairs(uwsgi_configuration_options) do
            local pattern = option.name:gsub("%-", "%%-")
            local disabled, value = line:match("^%s*(;?)%s*" .. pattern .. "%s*=%s*([+-]?%d+)")
            if value then
                if include_state then
                    preferences._present[option.preference] = true
                end
                preferences[option.preference] = normalize_integer_value(value, option.default_value)
                if option.enabled_preference then
                    preferences[option.enabled_preference] = disabled == ";" and 0 or 1
                end
            end
        end
    end

    return preferences
end

local function read_nginx_preferences()
    local nixio_fs = require "nixio.fs"
    local content = nixio_fs.readfile(nginx_template_file)
    local preferences = {
        nginx_config_available = content ~= nil,
        uwsgi_request_buffering = 0,
        client_max_body_size = 128
    }

    if not content then
        return preferences
    end

    for line in content:gmatch("[^\r\n]+") do
        local buffering = line:match("^%s*uwsgi_request_buffering%s+([^;]+);%s*$")
        if buffering then
            buffering = tostring(buffering):lower():match("^%s*(.-)%s*$")
            preferences.uwsgi_request_buffering = buffering == "on" and 1 or 0
        end

        local body_size = line:match("^%s*client_max_body_size%s+([^;]+);%s*$")
        if body_size then
            body_size = tostring(body_size):lower():match("^%s*(.-)%s*$")
            if body_size == "0" then
                preferences.client_max_body_size = 0
            else
                preferences.client_max_body_size = normalize_nginx_body_size(
                    body_size:match("^(%d+)m$") or body_size:match("^(%d+)$"),
                    preferences.client_max_body_size
                )
            end
        end
    end

    return preferences
end

local function read_uhttpd_preferences()
    local nixio_fs = require "nixio.fs"
    local uci = require("luci.model.uci").cursor()
    local preferences = {
        uhttpd_config_available = nixio_fs.access("/etc/config/uhttpd") == true,
        uhttpd_script_timeout = uhttpd_script_timeout_default,
        uhttpd_network_timeout = uhttpd_network_timeout_default
    }

    local ok, script_timeout = pcall(function()
        return uci:get("uhttpd", "main", "script_timeout")
    end)
    if ok then
        preferences.uhttpd_script_timeout = normalize_timeout_value(
            script_timeout,
            preferences.uhttpd_script_timeout
        )
    end

    local network_ok, network_timeout = pcall(function()
        return uci:get("uhttpd", "main", "network_timeout")
    end)
    if network_ok then
        preferences.uhttpd_network_timeout = normalize_timeout_value(
            network_timeout,
            preferences.uhttpd_network_timeout
        )
    end

    return preferences
end

local function save_basic_preferences(view_mode, allow_system_operations, show_hidden_files, home_dir, enable_thumbnails, editor_auto_indent, editor_auto_wrap, restore_last_directory)
    local uci = require("luci.model.uci").cursor()
    ensure_preference_section(uci)
    uci:set("harbor_file", "main", "view_mode", tostring(view_mode))
    uci:set("harbor_file", "main", "allow_system_operations", tostring(allow_system_operations))
    uci:set("harbor_file", "main", "show_hidden_files", tostring(show_hidden_files))
    uci:set("harbor_file", "main", "home_dir", normalize_home_dir(home_dir))
    uci:set("harbor_file", "main", "enable_thumbnails", tostring(enable_thumbnails))
    uci:set("harbor_file", "main", "editor_auto_indent", tostring(editor_auto_indent))
    uci:set("harbor_file", "main", "editor_auto_wrap", tostring(editor_auto_wrap))
    uci:set("harbor_file", "main", "restore_last_directory", tostring(restore_last_directory))
    return uci:commit("harbor_file")
end

local function save_window_preferences(window_width, window_height, target)
    local uci = require("luci.model.uci").cursor()
    ensure_preference_section(uci)
    if target == "mobile" then
        uci:set("harbor_file", "main", "mobile_window_width", tostring(window_width))
        uci:set("harbor_file", "main", "mobile_window_height", tostring(window_height))
    else
        uci:set("harbor_file", "main", "window_width", tostring(window_width))
        uci:set("harbor_file", "main", "window_height", tostring(window_height))
    end
    return uci:commit("harbor_file")
end

local function save_last_directory(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
        return false
    end
    local uci = require("luci.model.uci").cursor()
    ensure_preference_section(uci)
    uci:set("harbor_file", "main", "last_directory", path)
    return uci:commit("harbor_file")
end

local function save_show_line_numbers(value)
    local uci = require("luci.model.uci").cursor()
    ensure_preference_section(uci)
    uci:set("harbor_file", "main", "show_line_numbers", tostring(value))
    return uci:commit("harbor_file")
end

local function is_system_path(path)
    local normalized = normalize_path(path)
    if not normalized then
        return false
    end
    for _, root in ipairs(system_folder_roots) do
        if is_child_path(normalized, root) then
            return true
        end
    end
    return false
end

local function system_operations_allowed()
    return read_preferences().allow_system_operations == 1
end

local function read_ttyd_config()
    local uci = require("luci.model.uci").cursor()
    local config = nil
    pcall(function()
        uci:foreach("ttyd", "ttyd", function(section)
            config = section
            return false
        end)
    end)
    return config or {}
end

local function ttyd_process_running()
    local process = io.popen("ps ww 2>/dev/null || ps w 2>/dev/null || ps 2>/dev/null", "r")
    if not process then
        return false
    end
    local running = false
    for line in process:lines() do
        if line:match("%sttyd") and not line:match("%sgrep%s") then
            running = true
            break
        end
    end
    process:close()
    return running
end

local function read_ttyd_info()
    local nixio_fs = require "nixio.fs"
    local config = read_ttyd_config()
    local executable = find_executable("ttyd")
    local init_script = nixio_fs.stat("/etc/init.d/ttyd")
    local config_file = nixio_fs.stat("/etc/config/ttyd")
    local running = ttyd_process_running()
    local url_override = config.url_override or config.url or config.path or ""
    local installed = executable ~= nil or init_script ~= nil or config_file ~= nil or running

    return {
        available = installed,
        port = normalize_port_number(config.port, 7681),
        ssl = to_boolean(config.ssl) and 1 or 0,
        url = type(url_override) == "string" and url_override or "",
        command = tostring(config.command or "/bin/login"),
        interface = tostring(config.interface or ""),
        installed = installed and 1 or 0,
        running = running and 1 or 0
    }
end

local function deny_system_operation()
    write_json_status(403, "Forbidden", { code = 1, message = _("System folder operations are disabled") })
    return false
end

local function get_package_type(name)
    local ext = get_ext(name)
    return package_ext_map[ext] and ext or nil
end

local function classify_preview(path, name)
    local ext = get_ext(name)
    if image_mime_map[ext] then
        return "image"
    end
    if text_ext_map[ext] then
        return "text"
    end
    if video_mime_map[ext] then
        return "video"
    end
    if pdf_mime_map[ext] then
        return "pdf"
    end
    if package_ext_map[ext] then
        return "package"
    end
    if ext == "" and is_child_path(path, "/etc") then
        return "text"
    end
    return "none"
end

find_executable = function(name)
    local nixio_fs = require "nixio.fs"
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local search_paths = {}
    local seen = {}
    for entry in tostring(luci.http.getenv("PATH") or "/usr/sbin:/usr/bin:/sbin:/bin"):gmatch("[^:]+") do
        if not seen[entry] then
            table.insert(search_paths, entry)
            seen[entry] = true
        end
    end
    for _, entry in ipairs({ "/usr/sbin", "/usr/bin", "/sbin", "/bin" }) do
        if not seen[entry] then
            table.insert(search_paths, entry)
            seen[entry] = true
        end
    end
    for _, base in ipairs(search_paths) do
        local path = join_path(base, name)
        if nixio_fs.access(path, "x") then
            return path
        end
    end
    return nil
end

local function collect_thumbnail_images(path, show_hidden_files)
    local nixio_fs = require "nixio.fs"
    local normalized = normalize_path(path)
    local stat = normalized and nixio_fs.stat(normalized) or nil
    if not normalized or not stat or stat.type ~= "dir" then
        return nil, "invalid directory"
    end

    local iterator = nixio_fs.dir(normalized)
    if not iterator then
        return nil, "read directory failed"
    end

    local images = {}
    for name in iterator do
        if show_hidden_files == 1 or not is_hidden_file_name(name) then
            local item_path = normalize_path(join_path(normalized, name))
            local item_stat = item_path and nixio_fs.stat(item_path) or nil
            if item_stat and item_stat.type == "reg" and classify_preview(item_path, name) == "image" then
                table.insert(images, {
                    name = name,
                    path = item_path,
                    size = item_stat.size or 0,
                    mtime = item_stat.mtime or 0
                })
            end
        end
    end

    table.sort(images, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return images
end

local function validate_package_file(path)
    local nixio_fs = require "nixio.fs"
    local normalized = normalize_path(path)
    local stat = normalized and nixio_fs.lstat(normalized) or nil
    local package_type = normalized and get_package_type(normalized) or nil
    if not normalized or not stat or stat.type ~= "reg" or not package_type then
        return nil, nil, _("Invalid package file")
    end
    return normalized, package_type, nil
end

local function get_available_memory_kb()
    local fd = io.open("/proc/meminfo", "r")
    if not fd then
        return nil
    end
    local available, free, buffers, cached
    for line in fd:lines() do
        local key, value = line:match("^(%S+):%s*(%d+)")
        if key == "MemAvailable" then
            available = tonumber(value)
            break
        elseif key == "MemFree" then
            free = tonumber(value)
        elseif key == "Buffers" then
            buffers = tonumber(value)
        elseif key == "Cached" then
            cached = tonumber(value)
        end
    end
    fd:close()
    return available or (free and (free + (buffers or 0) + (cached or 0))) or nil
end

local function task_process_running(pid)
    local nixio_fs = require "nixio.fs"
    local number = tonumber(pid)
    if not number or number <= 0 then
        return false
    end
    return nixio_fs.stat("/proc/" .. tostring(math.floor(number))) ~= nil
end

local function read_package_install_state()
    local state = read_json_file(package_install_state_file)
    if not state then
        return nil
    end
    if (state.state == "pending" or state.state == "running") and not task_process_running(state.pid) then
        state.state = "failed"
        state.done = true
        state.success = false
        state.message = _("Install task ended unexpectedly")
        state.finished_at = state.finished_at or current_timestamp()
        state.exit_code = state.exit_code or -1
        write_json_file(package_install_state_file, state)
    end
    return state
end

local function write_package_install_state(state)
    return write_json_file(package_install_state_file, state)
end

local function build_package_install_response(state)
    return {
        task_id = state.task_id,
        state = state.state,
        done = state.done == true,
        success = state.success == true,
        message = state.message or "",
        exit_code = state.exit_code,
        package_type = state.package_type,
        installer = state.installer,
        path = state.path,
        package_name = state.package_name,
        started_at = state.started_at,
        finished_at = state.finished_at,
        log = read_log_file(package_install_log_file, package_install_log_limit)
    }
end

local function create_package_install_task(path, package_type)
    local task_id = string.format("%s-%d", tostring(math.floor(video_now_ms() or 0)), math.floor(os.time() % 100000))
    return {
        task_id = task_id,
        state = "pending",
        done = false,
        success = false,
        message = _("Preparing package install"),
        exit_code = nil,
        package_type = package_type,
        installer = package_ext_map[package_type].installer,
        path = path,
        started_at = current_timestamp(),
        finished_at = nil,
        pid = nil
    }
end

local function detect_package_installer()
    if find_executable("opkg") then
        return "opkg"
    end
    if find_executable("apk") then
        return "apk"
    end
    return nil
end

local function detect_nginx_installer()
    if find_executable("apk") then
        return "apk"
    end
    if find_executable("opkg") then
        return "opkg"
    end
    return nil
end

local function create_repository_install_task(package_name, installer)
    local task_id = string.format("%s-%d", tostring(math.floor(video_now_ms() or 0)), math.floor(os.time() % 100000))
    return {
        task_id = task_id,
        state = "pending",
        done = false,
        success = false,
        message = _("Preparing package install"),
        exit_code = nil,
        package_type = "repository",
        installer = installer,
        path = "",
        package_name = package_name,
        started_at = current_timestamp(),
        finished_at = nil,
        pid = nil
    }
end

local function build_package_install_command(task)
    local executable = find_executable(task.installer)
    if not executable then
        return nil, nil, _("Installer command not found")
    end
    if task.package_name and task.package_name ~= "" then
        if task.installer == "apk" then
            return executable, { "add", "--allow-untrusted", task.package_name }, nil
        end
        return executable, { "install", task.package_name }, nil
    end
    if task.package_type == "apk" then
        return executable, { "add", "--allow-untrusted", task.path }, nil
    end
    return executable, { "install", task.path }, nil
end

local function build_package_index_update_command(task)
    local executable = find_executable(task.installer)
    if not executable then
        return nil, nil, _("Installer command not found")
    end
    if task.installer == "apk" then
        return executable, { "update", "--allow-untrusted" }, nil
    end
    return executable, { "update" }, nil
end

local function command_to_shell(executable, args)
    local parts = { shell_quote(executable) }
    for _, arg in ipairs(args or {}) do
        table.insert(parts, shell_quote(arg))
    end
    return table.concat(parts, " ")
end

local function parse_execute_result(...)
    local values = { ... }
    if #values >= 3 then
        local ok = values[1]
        local how = values[2]
        local code = tonumber(values[3]) or -1
        if ok == true and how == "exit" and code == 0 then
            return 0
        end
        return code
    end
    if #values >= 1 then
        local code = values[1]
        if type(code) == "number" then
            if code > 255 then
                return math.floor(code / 256)
            end
            return code
        end
        if code == true then
            return 0
        end
    end
    return -1
end

local function replace_nginx_directive(content, directive, value)
    local count = 0
    local updated = content:gsub(
        "([^\r\n]+)",
        function(line)
            local indent = line:match("^([ \t]*)" .. directive .. "%s+[^;]+;%s*$")
            if indent and count == 0 then
                count = 1
                return indent .. directive .. " " .. value .. ";"
            end
            return line
        end
    )
    return updated, count > 0
end

local function insert_nginx_directive(content, directive, value)
    local count = 0
    local updated = content:gsub(
        "([^\r\n]+)",
        function(line)
            local indent = line:match("^([ \t]*)" .. nginx_insert_anchor .. "%s+[^;]+;%s*$")
            if indent and count == 0 then
                count = 1
                return line .. "\n" .. indent .. directive .. " " .. value .. ";"
            end
            return line
        end
    )
    return updated, count > 0
end

local function set_nginx_directive(content, directive, value)
    local updated, found = replace_nginx_directive(content, directive, value)
    if found then
        return updated, true
    end
    return insert_nginx_directive(updated, directive, value)
end

local function backup_config_file(path, content)
    local nixio_fs = require "nixio.fs"
    local backup_path = path .. ".harbor_file.bak"
    if not nixio_fs.writefile(backup_path, content) then
        return nil
    end
    return backup_path
end

local function restore_config_file(path, content)
    local nixio_fs = require "nixio.fs"
    return nixio_fs.writefile(path, content)
end

local function schedule_uwsgi_restart()
    local result = os.execute("(sleep 1; /etc/init.d/uwsgi restart >/dev/null 2>&1) >/dev/null 2>&1 &")
    return result ~= false and result ~= nil
end

local function read_uwsgi_form_preferences(current)
    local preferences = {}
    current = current or read_uwsgi_preferences()

    for _, option in ipairs(uwsgi_configuration_options) do
        preferences[option.preference] = normalize_integer_value(
            luci.http.formvalue(option.preference),
            current[option.preference] or option.default_value
        )
        if option.enabled_preference then
            preferences[option.enabled_preference] = normalize_preference_number(
                luci.http.formvalue(option.enabled_preference),
                current[option.enabled_preference] or option.default_enabled,
                valid_boolean_values
            )
        end
    end

    return preferences
end

local function uwsgi_preferences_changed(current, target)
    local present = current._present or {}
    for _, option in ipairs(uwsgi_configuration_options) do
        if not present[option.preference] then
            return true
        end
        if current[option.preference] ~= target[option.preference] then
            return true
        end
        if option.enabled_preference and current[option.enabled_preference] ~= target[option.enabled_preference] then
            return true
        end
    end
    return false
end

local function save_uwsgi_configuration(target)
    local nixio_fs = require "nixio.fs"
    local content = nixio_fs.readfile(uwsgi_config_file)
    if not content then
        return nil, _("uWSGI configuration file was not found")
    end

    local current = read_uwsgi_preferences(true)
    if not uwsgi_preferences_changed(current, target) then
        return true
    end

    local backup_path = backup_config_file(uwsgi_config_file, content)
    if not backup_path then
        return nil, _("Failed to backup uWSGI configuration")
    end

    local commands = {}
    for _, option in ipairs(uwsgi_configuration_options) do
        local disabled = option.enabled_preference and target[option.enabled_preference] ~= 1
        local prefix = disabled and ";" or ""
        local line = prefix .. option.name .. " = " .. tostring(target[option.preference])
        table.insert(commands, "sed -i " .. shell_quote("/^[;[:space:]]*" .. option.name .. "[[:space:]]*=.*/d") ..
            " " .. shell_quote(uwsgi_config_file))
        table.insert(commands, "echo " .. shell_quote(line) .. " >> " .. shell_quote(uwsgi_config_file))
    end

    if parse_execute_result(os.execute(table.concat(commands, " && "))) ~= 0 then
        restore_config_file(uwsgi_config_file, content)
        return nil, _("Failed to update uWSGI configuration")
    end
    if not schedule_uwsgi_restart() then
        restore_config_file(uwsgi_config_file, content)
        return nil, _("Failed to restart uWSGI")
    end
    nixio_fs.unlink(backup_path)
    return true
end

local function schedule_nginx_restart()
    local result = os.execute("(sleep 1; /etc/init.d/nginx restart >/dev/null 2>&1) >/dev/null 2>&1 &")
    return result ~= false and result ~= nil
end

local function schedule_uhttpd_restart()
    local result = os.execute("(sleep 1; /etc/init.d/uhttpd restart >/dev/null 2>&1) >/dev/null 2>&1 &")
    return result ~= false and result ~= nil
end

local function read_uhttpd_form_preferences(current)
    current = current or read_uhttpd_preferences()
    return {
        uhttpd_script_timeout = normalize_timeout_value(
            luci.http.formvalue("uhttpd_script_timeout"),
            current.uhttpd_script_timeout or uhttpd_script_timeout_default
        ),
        uhttpd_network_timeout = normalize_timeout_value(
            luci.http.formvalue("uhttpd_network_timeout"),
            current.uhttpd_network_timeout or uhttpd_network_timeout_default
        )
    }
end

local function ensure_uhttpd_section(uci)
    local ok, section = pcall(function()
        return uci:get("uhttpd", "main")
    end)
    if not ok or section == nil then
        uci:section("uhttpd", "uhttpd", "main", {})
    end
end

local function save_uhttpd_configuration(target)
    local uci = require("luci.model.uci").cursor()
    ensure_uhttpd_section(uci)
    uci:set("uhttpd", "main", "script_timeout", tostring(target.uhttpd_script_timeout))
    uci:set("uhttpd", "main", "network_timeout", tostring(target.uhttpd_network_timeout))
    if not uci:commit("uhttpd") then
        return nil, _("Failed to update uHTTPd configuration")
    end
    if not schedule_uhttpd_restart() then
        return nil, _("Failed to restart uHTTPd")
    end
    return true
end

local function read_nginx_form_preferences(current)
    current = current or read_nginx_preferences()
    return {
        uwsgi_request_buffering = normalize_preference_number(
            luci.http.formvalue("uwsgi_request_buffering"),
            current.uwsgi_request_buffering,
            valid_boolean_values
        ),
        client_max_body_size = normalize_nginx_body_size(
            luci.http.formvalue("client_max_body_size"),
            current.client_max_body_size
        )
    }
end

local function test_nginx_configuration()
    local command = "nginx -t -c " .. shell_quote(nginx_template_file) .. " >/dev/null 2>&1"
    return parse_execute_result(os.execute(command)) == 0
end

local function save_nginx_configuration(target)
    local nixio_fs = require "nixio.fs"
    local content = nixio_fs.readfile(nginx_template_file)
    if not content then
        return nil, _("Nginx configuration template was not found")
    end

    local updated = content
    for _, option in ipairs(nginx_configuration_options) do
        local preference_value = target[option.preference]
        local value = option.value and option.value(preference_value) or option.values[preference_value]
        local found
        updated, found = set_nginx_directive(updated, option.directive, value)
    end
    if updated == content then
        return true
    end

    local backup_path = backup_config_file(nginx_template_file, content)
    if not backup_path then
        return nil, _("Failed to backup Nginx configuration")
    end
    if not nixio_fs.writefile(nginx_template_file, updated) then
        restore_config_file(nginx_template_file, content)
        return nil, _("Failed to update Nginx configuration")
    end
    if not test_nginx_configuration() then
        restore_config_file(nginx_template_file, content)
        return nil, _("Nginx configuration test failed")
    end
    if not schedule_nginx_restart() then
        restore_config_file(nginx_template_file, content)
        return nil, _("Failed to restart Nginx")
    end
    nixio_fs.unlink(backup_path)
    return true
end

local function run_logged_command(executable, args, log_path)
    log_path = harbor_log_file
    local command = "mkdir -p /tmp/log; " .. command_to_shell(executable, args) .. " >> " .. shell_quote(log_path) .. " 2>&1"
    return parse_execute_result(os.execute(command))
end

function archive.run_shell(command, log_path)
    log_path = harbor_log_file
    return parse_execute_result(os.execute("mkdir -p /tmp/log; ( " .. tostring(command or "") .. " ) >> " .. shell_quote(log_path) .. " 2>&1"))
end

local function activate_nginx_web_server(log_path)
    log_path = harbor_log_file
    local command = table.concat({
        "if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd disable; /etc/init.d/uhttpd stop; fi",
        "/etc/init.d/uwsgi enable",
        "/etc/init.d/uwsgi restart",
        "/etc/init.d/nginx enable",
        "/etc/init.d/nginx restart"
    }, "; ")
    return parse_execute_result(os.execute(
        "mkdir -p /tmp/log; ( " .. command .. " ) >> " .. shell_quote(log_path) .. " 2>&1"
    ))
end

local function hex32(value)
    local number = math.floor(tonumber(value) or 0)
    local chars = "0123456789abcdef"
    local result = {}
    for index = 8, 1, -1 do
        local digit = number % 16
        result[index] = chars:sub(digit + 1, digit + 1)
        number = math.floor(number / 16)
    end
    return table.concat(result, "")
end

local function stable_hash(value)
    local text = tostring(value or "")
    local hash_a = 5381
    local hash_b = 2166136261
    for index = 1, #text do
        local byte = text:byte(index)
        hash_a = (hash_a * 33 + byte) % 4294967296
        hash_b = (hash_b * 65599 + byte) % 4294967296
    end
    return hex32(hash_a) .. hex32(hash_b)
end

local function thumbnail_cache_dir(preferences)
    local home_dir = normalize_home_dir(preferences and preferences.home_dir)
    return normalize_path(join_path(join_path(home_dir, ".cache"), "pictures"))
end

local function thumbnail_cache_key(path, stat)
    local size = stat and tonumber(stat.size) or 0
    local mtime = stat and tonumber(stat.mtime) or 0
    return stable_hash(table.concat({ normalize_path(path) or "", tostring(size), tostring(mtime), tostring(thumbnail_size), thumbnail_cache_version }, "|"))
end

local function thumbnail_cache_path(path, stat, preferences)
    local cache_dir = thumbnail_cache_dir(preferences)
    if not cache_dir then
        return nil
    end
    return join_path(cache_dir, thumbnail_cache_key(path, stat) .. ".jpg")
end

local function thumbnail_available(path, stat, preferences)
    local nixio_fs = require "nixio.fs"
    local cache_path = thumbnail_cache_path(path, stat, preferences)
    return cache_path and nixio_fs.stat(cache_path) ~= nil or false
end

local function detect_apk_package_name(path)
    local quoted_path = shell_quote(path)
    local process = io.popen("tar -xOf " .. quoted_path .. " .PKGINFO 2>/dev/null", "r")
    if process then
        local content = process:read("*a") or ""
        process:close()
        local pkgname = content:match("\npkgname%s*=%s*([^\n\r]+)") or content:match("^pkgname%s*=%s*([^\n\r]+)")
        if pkgname and pkgname ~= "" then
            return pkgname:gsub("%s+$", "")
        end
    end

    local base_name = tostring(path or ""):match("([^/]+)$") or ""
    local package_name = base_name:match("^(.+)_([^_]+)_([^_]+)%.apk$")
    if package_name and package_name ~= "" then
        return package_name
    end
    package_name = base_name:match("^(.+)%-%d[%w%.%+%-%_~]*%.apk$")
    if package_name and package_name ~= "" then
        return package_name
    end
    return base_name:gsub("%.apk$", "")
end

local function apk_package_installed(path)
    local executable = find_executable("apk")
    local package_name = detect_apk_package_name(path)
    if not executable or not package_name or package_name == "" then
        return false
    end
    local command = command_to_shell(executable, { "info", "-e", package_name }) .. " >/dev/null 2>&1"
    return parse_execute_result(os.execute(command)) == 0
end

local function has_package_index_cache(installer)
    local nixio_fs = require "nixio.fs"
    local roots = package_index_cache_roots[installer]
    if type(roots) ~= "table" then
        return false
    end

    for _, root in ipairs(roots) do
        local stat = nixio_fs.stat(root)
        if stat and stat.type == "dir" then
            local matched_groups = {}
            local iterator = nixio_fs.dir(root)
            if iterator then
                for name in iterator do
                    if name ~= "." and name ~= ".." then
                        local path = join_path(root, name)
                        local file_stat = nixio_fs.stat(path)
                        if file_stat and file_stat.type == "reg" and (file_stat.size or 0) > 0 then
                            if installer == "opkg" then
                                local lower_name = name:lower()
                                for index, aliases in ipairs(opkg_required_feed_groups) do
                                    if not matched_groups[index] then
                                        for _, alias in ipairs(aliases) do
                                            if lower_name:find(alias, 1, true) then
                                                matched_groups[index] = true
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            if installer ~= "opkg" and (name:match("^APKINDEX") or name:match("%.adb$") or name:match("%.tar%.gz$")) then
                                return true
                            end
                        end
                    end
                end
            end
            if installer == "opkg" then
                local complete = true
                for index = 1, #opkg_required_feed_groups do
                    if not matched_groups[index] then
                        complete = false
                        break
                    end
                end
                if complete then
                    return true
                end
            end
        end
    end
    return false
end

local function run_package_install_task(task)
    local nixio_fs = require "nixio.fs"
    local nixio = require "nixio"
    if task.activate_nginx then
        os.execute("sleep 2")
    end
    local executable, args, cmd_err = build_package_install_command(task)
    if not executable then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = cmd_err
        task.exit_code = -1
        task.finished_at = current_timestamp()
        write_package_install_state(task)
        return
    end

    clear_log()
    hb_log(package_install_log_file, "==== Package install task start ====")
    hb_log(package_install_log_file, "Start " .. task.installer .. " install: " .. (task.package_name or task.path))
    task.state = "running"
    task.message = _("Checking package index")
    task.pid = nixio.getpid()
    write_package_install_state(task)
    hb_log(package_install_log_file, "Checking package index state")
    if not has_package_index_cache(task.installer) then
        local update_executable, update_args, update_err = build_package_index_update_command(task)
        if not update_executable then
            task.state = "failed"
            task.done = true
            task.success = false
            task.message = update_err
            task.exit_code = -1
            task.finished_at = current_timestamp()
            write_package_install_state(task)
            return
        end
        hb_log(package_install_log_file, "Package index is not ready, running update")
        task.message = _("Updating package index")
        write_package_install_state(task)
        local update_exit_code = run_logged_command(update_executable, update_args, package_install_log_file)
        if update_exit_code ~= 0 then
            hb_log(package_install_log_file, "Package index update failed with code " .. tostring(update_exit_code))
            task.state = "failed"
            task.done = true
            task.success = false
            task.message = _("Package index update failed")
            task.exit_code = update_exit_code
            task.finished_at = current_timestamp()
            write_package_install_state(task)
            return
        end
        hb_log(package_install_log_file, "Package index updated successfully")
    else
        hb_log(package_install_log_file, "Package index is ready")
    end

    task.message = _("Installing package")
    write_package_install_state(task)
    local exit_code = run_logged_command(executable, args, package_install_log_file)
    local success = exit_code == 0
    local warning_success = false
    if not success and task.package_type == "apk" and apk_package_installed(task.path) then
        warning_success = true
        success = true
        hb_log(package_install_log_file, "apk reported non-zero exit code but target package is installed; treating as success with warnings")
    end
    if success and task.activate_nginx then
        local activate_exit_code = activate_nginx_web_server(package_install_log_file)
        if activate_exit_code ~= 0 then
            success = false
            exit_code = activate_exit_code
            hb_log(package_install_log_file, "Failed to activate nginx with code " .. tostring(activate_exit_code))
        end
    end
    hb_log(package_install_log_file, success and "Install finished successfully" or ("Install failed with code " .. tostring(exit_code)))

    task.state = success and "success" or "failed"
    task.done = true
    task.success = success
    task.message = success and (warning_success and _("Package installed with warnings") or _("Package installed successfully")) or _("Package installation failed")
    task.exit_code = exit_code
    task.finished_at = current_timestamp()
    write_package_install_state(task)
end

local function start_package_install_task(task)
    local nixio = require "nixio"
    local pid = nixio.fork()
    if not pid or pid < 0 then
        return nil, "fork package task failed"
    end
    if pid == 0 then
        pcall(nixio.setsid)
        local ok, err = pcall(run_package_install_task, task)
        if not ok then
            task.state = "failed"
            task.done = true
            task.success = false
            task.message = _("Package installation failed")
            task.exit_code = -1
            task.finished_at = current_timestamp()
            hb_log(package_install_log_file, "install runtime error: " .. tostring(err))
            write_package_install_state(task)
        end
        os.exit(0)
    end
    task.pid = pid
    task.state = "running"
    task.message = _("Installing package")
    write_package_install_state(task)
    return pid, nil
end

local function read_thumbnail_task_state()
    local state = read_json_file(thumbnail_task_state_file)
    if not state then
        return nil
    end
    if state.state == "running" and not task_process_running(state.pid) then
        state.state = "failed"
        state.done = true
        state.success = false
        state.message = _("Thumbnail generation ended unexpectedly")
        state.finished_at = state.finished_at or current_timestamp()
        write_json_file(thumbnail_task_state_file, state)
    elseif state.state == "pending" then
        local stale = true
        local started = state.started_at
        if started then
            local y, m, d, H, M, S = started:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
            if y then
                local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d),
                    hour = tonumber(H), min = tonumber(M), sec = tonumber(S) })
                stale = os.difftime(os.time(), t) > 30
            end
        end
        if stale then
            state.state = "failed"
            state.done = true
            state.success = false
            state.message = _("Thumbnail generation ended unexpectedly")
            state.finished_at = state.finished_at or current_timestamp()
            write_json_file(thumbnail_task_state_file, state)
        end
    end
    return state
end

local function write_thumbnail_task_state(state)
    return write_json_file(thumbnail_task_state_file, state)
end

local function build_thumbnail_task_response(state)
    return {
        task_id = state.task_id,
        state = state.state,
        done = state.done == true,
        success = state.success == true,
        message = state.message or "",
        path = state.path,
        total = tonumber(state.total) or 0,
        processed = tonumber(state.processed) or 0,
        success_count = tonumber(state.success_count) or 0,
        failed_count = tonumber(state.failed_count) or 0,
        cached_count = tonumber(state.cached_count) or 0,
        current_file = state.current_file or "",
        started_at = state.started_at,
        finished_at = state.finished_at,
        log = read_log_file(thumbnail_task_log_file, thumbnail_task_log_limit)
    }
end

local function create_thumbnail_task(path, preferences, total)
    local task_id = "thumb-" .. tostring(math.floor(video_now_ms() or 0)) .. "-" .. tostring(math.floor(os.time() % 100000))
    return {
        task_id = task_id,
        state = "pending",
        done = false,
        success = false,
        message = _("Preparing thumbnails"),
        path = path,
        home_dir = preferences.home_dir,
        show_hidden_files = preferences.show_hidden_files,
        total = total or 0,
        processed = 0,
        success_count = 0,
        failed_count = 0,
        cached_count = 0,
        current_file = "",
        pid = nil,
        started_at = current_timestamp(),
        finished_at = nil
    }
end

local function build_thumbnail_command(gm_path, source_path, target_path)
    local hint = tostring(thumbnail_size * 2) .. "x" .. tostring(thumbnail_size * 2)
    local gm_args = {
        "convert",
        "-size", hint,
        source_path,
        "-auto-orient",
        "-thumbnail",
        tostring(thumbnail_size) .. "x" .. tostring(thumbnail_size) .. ">",
        "-background",
        "white",
        "-flatten",
        "+profile", "*",
        "-quality", "80",
        target_path
    }
    local nice_path = find_executable("nice")
    if nice_path then
        return nice_path, { "-n", "10", gm_path, unpack(gm_args) }
    end
    return gm_path, gm_args
end

local function run_thumbnail_task(task)
    local nixio_fs = require "nixio.fs"
    clear_log()
    local gm_path = find_executable("gm")
    if not gm_path then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("GraphicsMagick command not found")
        task.finished_at = current_timestamp()
        write_thumbnail_task_state(task)
        hb_log(thumbnail_task_log_file, "gm command not found")
        return
    end

    local preferences = {
        home_dir = task.home_dir,
        show_hidden_files = task.show_hidden_files
    }
    local cache_dir = thumbnail_cache_dir(preferences)
    if not cache_dir or not mkdir_p(cache_dir) then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Thumbnail cache directory is not writable")
        task.finished_at = current_timestamp()
        write_thumbnail_task_state(task)
        hb_log(thumbnail_task_log_file, "cache directory is not writable")
        return
    end

    local images, err = collect_thumbnail_images(task.path, task.show_hidden_files)
    if not images then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = err or _("Thumbnail generation failed")
        task.finished_at = current_timestamp()
        write_thumbnail_task_state(task)
        hb_log(thumbnail_task_log_file, task.message)
        return
    end

    task.state = "running"
    task.message = _("Generating thumbnails")
    task.total = #images
    write_thumbnail_task_state(task)
    hb_log(thumbnail_task_log_file, "Start thumbnail generation: " .. task.path)

    for _, item in ipairs(images) do
        local stat = nixio_fs.stat(item.path)
        local cp = stat and thumbnail_cache_path(item.path, stat, preferences) or nil
        item.has_cache = cp and nixio_fs.stat(cp) ~= nil or false
    end
    table.sort(images, function(a, b)
        if a.has_cache ~= b.has_cache then
            return not a.has_cache
        end
        return (a.size or 0) < (b.size or 0)
    end)

    for _, item in ipairs(images) do
        task.current_file = item.name
        write_thumbnail_task_state(task)

        local stat = nixio_fs.stat(item.path)
        local cache_path = stat and thumbnail_cache_path(item.path, stat, preferences) or nil
        if cache_path and nixio_fs.stat(cache_path) then
            task.cached_count = task.cached_count + 1
        elseif cache_path then
            local temp_path = cache_path .. ".tmp." .. task.task_id
            os.remove(temp_path)
            local executable, args = build_thumbnail_command(gm_path, item.path, temp_path)
            local exit_code = run_logged_command(executable, args, thumbnail_task_log_file)
            if exit_code == 0 and nixio_fs.stat(temp_path) and os.rename(temp_path, cache_path) then
                task.success_count = task.success_count + 1
            else
                os.remove(temp_path)
                task.failed_count = task.failed_count + 1
                hb_log(thumbnail_task_log_file, "Failed: " .. item.name .. " code=" .. tostring(exit_code))
            end
        else
            task.failed_count = task.failed_count + 1
            hb_log(thumbnail_task_log_file, "Failed: " .. item.name .. " cache path unavailable")
        end

        task.processed = task.processed + 1
        write_thumbnail_task_state(task)
    end

    task.done = true
    task.success = task.failed_count == 0
    task.state = task.success and "success" or "failed"
    task.message = task.success and _("Thumbnail generation complete") or _("Thumbnail generation failed")
    task.current_file = ""
    task.finished_at = current_timestamp()
    write_thumbnail_task_state(task)
    hb_log(thumbnail_task_log_file, task.message)
end

local function start_thumbnail_task(task)
    local nixio = require "nixio"
    local pid = nixio.fork()
    if not pid or pid < 0 then
        return nil, "fork thumbnail task failed"
    end
    if pid == 0 then
        pcall(nixio.setsid)
        task.pid = nixio.getpid()
        task.state = "running"
        task.message = _("Generating thumbnails")
        write_thumbnail_task_state(task)
        local ok, err = pcall(run_thumbnail_task, task)
        if not ok then
            task.state = "failed"
            task.done = true
            task.success = false
            task.message = _("Thumbnail generation failed")
            task.finished_at = current_timestamp()
            hb_log(thumbnail_task_log_file, "thumbnail runtime error: " .. tostring(err))
            write_thumbnail_task_state(task)
        end
        os.exit(0)
    end
    return pid, nil
end

local function parse_size(value)
    if not value or not tostring(value):match("^%d+$") then
        return nil
    end
    local size = tonumber(value)
    if not size or size < 0 then
        return nil
    end
    return math.floor(size)
end

local function parse_binary_number(value, default_value)
    if value == nil or value == "" then
        return default_value
    end
    local text = tostring(value):lower()
    local number
    if text:match("^0x[%da-f]+$") then
        number = tonumber(text:sub(3), 16)
    elseif text:match("^%d+$") then
        number = tonumber(text)
    else
        return nil
    end
    if not number or number < 0 then
        return nil
    end
    return math.floor(number)
end

local function validate_upload_name(name)
    if type(name) ~= "string" or name == "" or name == "." or name == ".." then
        return false
    end
    if name:find("[\\/]") or name:find("[%z\1-\31\127]") then
        return false
    end
    return true
end

local function validate_write_request()
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        write_json_status(400, "Bad Request", { code = 1, message = "POST required" })
        return false
    end
    return true
end

local function get_writable_directory(path)
    local nixio_fs = require "nixio.fs"
    local normalized = normalize_path(path)
    local stat = normalized and nixio_fs.stat(normalized) or nil
    if not normalized or not stat or stat.type ~= "dir" then
        return nil, "directory not found"
    end
    if not nixio_fs.access(normalized, "w") then
        return nil, "directory is not writable"
    end
    return normalized
end

local function calculate_operation_space_margin(total_bytes)
    local total = tonumber(total_bytes) or 0
    if total <= 0 then
        return 0
    end
    return math.ceil(total * operation_space_ratio)
end

local function get_directory_space_info(path)
    local nixio_fs = require "nixio.fs"
    local normalized = normalize_path(path)
    if not normalized then
        return nil, nil, nil, "invalid directory"
    end
    local vfs = nixio_fs.statvfs(normalized)
    if not vfs then
        return nil, nil, nil, "read filesystem space failed"
    end
    local block_size = tonumber(vfs.frsize) or tonumber(vfs.bsize) or 0
    local available = (tonumber(vfs.bavail) or 0) * block_size
    local total = (tonumber(vfs.blocks) or 0) * block_size
    return available, total, calculate_operation_space_margin(total)
end

local function get_directory_available_bytes(path)
    local available, _, _, err = get_directory_space_info(path)
    if not available then
        return nil, err
    end
    return available
end

local function ensure_directory_space(path, required_bytes)
    local available, total, margin, err = get_directory_space_info(path)
    if not available then
        return false, 0, err
    end
    local required = (tonumber(required_bytes) or 0) + (margin or 0)
    if available < required then
        return false, available, insufficient_space_message, required
    end
    return true, available, nil, required
end

local function read_mount_paths()
    local mounts = {}
    local fd = io.open("/proc/self/mounts", "r") or io.open("/proc/mounts", "r")
    if not fd then
        return mounts
    end
    for line in fd:lines() do
        local path = line:match("^%S+%s+(%S+)")
        if path then
            path = path:gsub("\\(%d%d%d)", function(value)
                return string.char(tonumber(value, 8))
            end)
            mounts[path] = true
        end
    end
    fd:close()
    return mounts
end

local function contains_mount(path, mounts)
    for mount_path in pairs(mounts) do
        if mount_path == path or is_child_path(mount_path, path) then
            return true
        end
    end
    return false
end

local function remove_tree(path)
    local nixio_fs = require "nixio.fs"
    local stat = nixio_fs.lstat(path)
    if not stat then
        return false, "path not found"
    end
    if stat.type ~= "dir" then
        return nixio_fs.unlink(path) and true or false, "delete file failed"
    end

    local iterator = nixio_fs.dir(path)
    if not iterator then
        return false, "read directory failed"
    end
    for name in iterator do
        local ok, err = remove_tree(join_path(path, name))
        if not ok then
            return false, err
        end
    end
    return nixio_fs.rmdir(path) and true or false, "delete directory failed"
end

local function copy_regular_file(source, target)
    local nixio_fs = require "nixio.fs"
    local input = io.open(source, "rb")
    if not input then
        return false, "open source file failed"
    end
    local output = io.open(target, "wb")
    if not output then
        input:close()
        return false, "create target file failed"
    end
    while true do
        local data = input:read(65536)
        if not data or #data == 0 then
            break
        end
        if not output:write(data) then
            input:close()
            output:close()
            nixio_fs.unlink(target)
            return false, "write target file failed"
        end
    end
    input:close()
    output:close()
    return true
end

local function copy_tree(source, target)
    local nixio_fs = require "nixio.fs"
    local stat = nixio_fs.lstat(source)
    if not stat then
        return false, "source not found"
    end
    if stat.type == "lnk" then
        local link_target = nixio_fs.readlink(source)
        return link_target and nixio_fs.symlink(link_target, target) and true or false, "copy symbolic link failed"
    end
    if stat.type == "reg" then
        return copy_regular_file(source, target)
    end
    if stat.type ~= "dir" then
        return false, "unsupported source type"
    end
    if not nixio_fs.mkdir(target) then
        return false, "create target directory failed"
    end
    local iterator = nixio_fs.dir(source)
    if not iterator then
        nixio_fs.rmdir(target)
        return false, "read source directory failed"
    end
    for name in iterator do
        local ok, err = copy_tree(join_path(source, name), join_path(target, name))
        if not ok then
            remove_tree(target)
            return false, err
        end
    end
    return true
end

local function cleanup_stale_uploads(dir)
    local nixio_fs = require "nixio.fs"
    local iterator = nixio_fs.dir(dir)
    if not iterator then
        return
    end
    local now = os.time()
    for name in iterator do
        if name:sub(1, 15) == ".harbor-upload-" then
            local path = join_path(dir, name)
            local stat = nixio_fs.stat(path)
            if stat and stat.type == "reg" and now - (stat.mtime or 0) > 120 then
                nixio_fs.unlink(path)
            end
        end
    end
end

local function get_upload_directory(path)
    local nixio_fs = require "nixio.fs"
    local normalized = normalize_path(path)
    if not normalized then
        return nil, nil, "invalid target directory"
    end

    local stat = nixio_fs.stat(normalized)
    if not stat or stat.type ~= "dir" then
        return nil, nil, "target directory not found"
    end
    if not nixio_fs.access(normalized, "w") then
        return nil, nil, "target directory is not writable"
    end

    cleanup_stale_uploads(normalized)
    local available, _, operation_space_margin, space_err = get_directory_space_info(normalized)
    if not available then
        return nil, nil, nil, space_err
    end
    return normalized, available, operation_space_margin or 0
end

local function parse_upload_names(value)
    local json = require "luci.jsonc"
    local ok, names = pcall(json.parse, value or "")
    if not ok or type(names) ~= "table" or #names == 0 then
        return nil, "invalid file list"
    end

    local result = {}
    local seen = {}
    for _, name in ipairs(names) do
        if not validate_upload_name(name) then
            return nil, "invalid file name"
        end
        if seen[name] then
            return nil, "duplicate file name in upload batch"
        end
        seen[name] = true
        table.insert(result, name)
    end
    return result
end

is_hidden_file_name = function(name)
    return type(name) == "string" and name:sub(1, 1) == "."
end

local function list_directory(path, preferences)
    local nixio_fs = require "nixio.fs"
    preferences = preferences or read_preferences()
    local show_hidden_files = preferences.show_hidden_files
    local stat = nixio_fs.stat(path)
    if not stat then
        return nil, "path not found"
    end
    if stat.type ~= "dir" then
        return nil, "path is not directory"
    end

    local iterator = nixio_fs.dir(path)
    if not iterator then
        return nil, "read directory failed"
    end

    local items = {}
    for name in iterator do
        if show_hidden_files == 1 or not is_hidden_file_name(name) then
            local item_path = normalize_path(join_path(path, name))
            local item_stat = item_path and nixio_fs.stat(item_path) or nil
            if item_stat then
                local item_type = item_stat.type == "dir" and "directory" or "file"
                local preview = item_type == "file" and classify_preview(item_path, name) or "none"
                local item = {
                    name = name,
                    path = item_path,
                    type = item_type,
                    size = item_stat.size or 0,
                    mtime = item_stat.mtime or 0,
                    ext = get_ext(name),
                    preview = preview,
                    mode = tostring(item_stat.modedec or 0)
                }
                if preferences.enable_thumbnails == 1 and preview == "image" then
                    item.thumbnail_available = thumbnail_available(item_path, item_stat, preferences)
                end
                table.insert(items, item)
            end
        end
    end

    table.sort(items, function(a, b)
        if a.type ~= b.type then
            return a.type == "directory"
        end
        return a.name:lower() < b.name:lower()
    end)

    return items
end

local function list_root_folders()
    local preferences = read_preferences()
    preferences.enable_thumbnails = 0
    local items, err = list_directory("/", preferences)
    if not items then
        return {}, err
    end

    local folders = {}
    for _, item in ipairs(items) do
        if item.type == "directory" then
            table.insert(folders, item)
        end
    end
    return folders
end

local function drive_name(device, mount_point)
    local i18n = require "luci.i18n"
    if mount_point == "/" then
        return i18n.translate("System Disk")
    end
    if mount_point == "/tmp" then
        return i18n.translate("Temporary Space")
    end

    local name = device:match("([^/]+)$")
    return name and name ~= "" and name or device
end

local function list_drives()
    local i18n = require "luci.i18n"
    local drives = {}
    local seen_mount = {}
    local seen_drive = {}
    local process = io.popen("df -kP 2>/dev/null", "r")

    if process then
        process:read("*l")
        for line in process:lines() do
            local device, total, used, available, percent, mount_point =
                line:match("^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%%%s+(.+)$")

            local is_root = mount_point == "/"
            local is_temporary_space = mount_point == "/tmp"
            local is_device = device and device:match("^/dev/") ~= nil
            local name = drive_name(device, mount_point)
            local drive_key = (name and name ~= "" and name or device or mount_point or ""):lower()

            if mount_point and not seen_mount[mount_point] and not hidden_mounts[mount_point] and (is_root or is_temporary_space or is_device) then
                seen_mount[mount_point] = true
                if not seen_drive[drive_key] then
                    seen_drive[drive_key] = true
                    table.insert(drives, {
                        name = name,
                        device = device,
                        path = mount_point,
                        total_kb = tonumber(total) or 0,
                        used_kb = tonumber(used) or 0,
                        available_kb = tonumber(available) or 0,
                        usage_percent = tonumber(percent) or 0
                    })
                end
            end
        end
        process:close()
    end

    if not seen_mount["/"] then
        table.insert(drives, 1, {
            name = i18n.translate("System Disk"),
            device = "rootfs",
            path = "/",
            total_kb = 0,
            used_kb = 0,
            available_kb = 0,
            usage_percent = 0
        })
    end

    table.sort(drives, function(a, b)
        if a.path == "/" then
            return true
        end
        if b.path == "/" then
            return false
        end
        return a.path:lower() < b.path:lower()
    end)
    return drives
end

function archive.task_id()
    return string.format("%s-%d", tostring(math.floor(video_now_ms() or 0)), math.floor(os.time() % 100000))
end

function archive.read_state()
    local state = read_json_file(archive.state_file)
    if not state then
        return nil
    end
    if (state.state == "pending" or state.state == "running") and not task_process_running(state.pid) then
        state.state = "failed"
        state.done = true
        state.success = false
        state.message = _("Archive task ended unexpectedly")
        state.finished_at = state.finished_at or current_timestamp()
        state.exit_code = state.exit_code or -1
        write_json_file(archive.state_file, state)
    end
    return state
end

function archive.write_state(state)
    return write_json_file(archive.state_file, state)
end

function archive.response(state)
    return {
        task_id = state.task_id,
        state = state.state,
        mode = state.mode,
        done = state.done == true,
        success = state.success == true,
        message = state.message or "",
        exit_code = state.exit_code,
        format = state.format,
        path = state.path,
        output_path = state.output_path,
        destination_path = state.destination_path,
        source_count = state.source_count,
        started_at = state.started_at,
        finished_at = state.finished_at,
        log = read_log_file(archive.log_file, archive.log_limit)
    }
end

function archive.file_name(path)
    return tostring(path or ""):match("([^/]+)$") or ""
end

function archive.detect_extract_format(path)
    local name = archive.file_name(path):lower()
    if name:match("%.tar%.gz$") then
        return "tar.gz"
    end
    if name:match("%.tgz$") then
        return "tgz"
    end
    if name:match("%.tar$") then
        return "tar"
    end
    if name:match("%.zip$") then
        return "zip"
    end
    if name:match("%.gz$") then
        return "gz"
    end
    return nil
end

function archive.strip_suffix(name, format)
    local lower = tostring(name or ""):lower()
    local value = tostring(name or "")
    local suffixes = {
        ["tar.gz"] = ".tar.gz",
        tgz = ".tgz",
        tar = ".tar",
        zip = ".zip",
        gz = ".gz"
    }
    local suffix = suffixes[format]
    if suffix and lower:sub(-#suffix) == suffix then
        return value:sub(1, #value - #suffix)
    end
    return value
end

function archive.ensure_extension(name, format)
    local info = archive.create_formats[format]
    local output_name = tostring(name or "")
    local lower = output_name:lower()
    if info and info.extension and lower:sub(-#info.extension) ~= info.extension then
        output_name = output_name .. info.extension
    end
    return output_name
end

function archive.source_size_estimate(path)
    local nixio_fs = require "nixio.fs"
    local stat = nixio_fs.lstat(path)
    if not stat then
        return 0
    end
    if stat.type == "reg" then
        return tonumber(stat.size) or 0
    end
    if stat.type ~= "dir" then
        return 0
    end
    local total = 0
    local iterator = nixio_fs.dir(path)
    if not iterator then
        return total
    end
    for name in iterator do
        total = total + archive.source_size_estimate(join_path(path, name))
    end
    return total
end

function archive.source_size(items)
    local total = 0
    for _, item in ipairs(items or {}) do
        total = total + archive.source_size_estimate(item.path)
    end
    return total
end

function archive.create_command(task)
    local format = archive.create_formats[task.format]
    if not format then
        return nil, _("Unsupported archive format")
    end
    local executable = find_executable(format.command)
    if not executable then
        return nil, _("Archive command not found")
    end
    -- Sources are addressed relative to the directory they all live in, while
    -- the output file may live in a different (user-chosen) target directory.
    local base_dir = task.source_dir or task.target_dir
    if task.format == "tar.gz" then
        local args = { "-czf", task.output_path, "-C", base_dir }
        for _, name in ipairs(task.names or {}) do
            table.insert(args, name)
        end
        return command_to_shell(executable, args)
    end
    if task.format == "tar" then
        local args = { "-cf", task.output_path, "-C", base_dir }
        for _, name in ipairs(task.names or {}) do
            table.insert(args, name)
        end
        return command_to_shell(executable, args)
    end
    if task.format == "zip" then
        -- zip stores relative names, so run it inside the source directory.
        local args = { "-r", task.output_path }
        for _, name in ipairs(task.names or {}) do
            table.insert(args, name)
        end
        return "cd " .. shell_quote(base_dir) .. " && " .. command_to_shell(executable, args)
    end
    return nil, _("Unsupported archive format")
end

function archive.extract_command(task)
    local info = archive.extract_formats[task.format]
    if not info then
        return nil, _("Unsupported archive format")
    end
    local executable = find_executable(info.command)
    if not executable then
        return nil, _("Archive command not found")
    end
    if task.format == "zip" then
        -- -o overwrites existing files without prompting.
        if task.overwrite then
            return command_to_shell(executable, { "-o", task.path, "-d", task.destination_path })
        end
        return command_to_shell(executable, { task.path, "-d", task.destination_path })
    end
    if task.format == "tar" or task.format == "tar.gz" or task.format == "tgz" then
        local flag = "-xf"
        if task.format == "tar.gz" or task.format == "tgz" then
            flag = "-xzf"
        end
        return command_to_shell(executable, { flag, task.path, "-C", task.destination_path })
    end
    if task.format == "gz" then
        return command_to_shell(executable, { "-dc", task.path }) .. " > " .. shell_quote(task.destination_path)
    end
    return nil, _("Unsupported archive format")
end

function archive.run_task(task)
    local nixio = require "nixio"
    local nixio_fs = require "nixio.fs"
    task.state = "running"
    task.pid = nixio.getpid()
    task.message = task.mode == "create" and _("Creating archive") or _("Extracting archive")
    archive.write_state(task)
    hb_log(archive.log_file, task.message)

    local command, command_err
    if task.mode == "create" then
        command, command_err = archive.create_command(task)
    else
        -- Merge-style overwrite: files from the archive replace matching ones
        -- while files already in the destination that are NOT in the archive
        -- are kept. zip uses `unzip -o`, tar/tar.gz overwrite natively.
        command, command_err = archive.extract_command(task)
        if not command_err and task.container then
            local dest_stat = nixio_fs.stat(task.destination_path)
            if not dest_stat then
                if not nixio_fs.mkdir(task.destination_path) then
                    command = nil
                    command_err = _("Create destination directory failed")
                end
            elseif dest_stat.type ~= "dir" then
                command = nil
                command_err = _("Create destination directory failed")
            end
        end
    end

    local exit_code = -1
    if command then
        exit_code = archive.run_shell(command, archive.log_file)
    else
        hb_log(archive.log_file, command_err or "archive command build failed")
    end

    local success = exit_code == 0
    if not success and task.mode == "extract" and task.format == "zip" and exit_code == 1 then
        success = true
        hb_log(archive.log_file, "unzip finished with warnings; treating exit code 1 as success")
    end
    if not success then
        if task.output_path then
            nixio_fs.unlink(task.output_path)
        end
        if task.container and task.destination_path then
            remove_tree(task.destination_path)
        elseif task.mode == "extract" and task.destination_path then
            nixio_fs.unlink(task.destination_path)
        end
    end
    hb_log(archive.log_file, success and "Archive task finished successfully" or ("Archive task failed with code " .. tostring(exit_code)))

    task.state = success and "success" or "failed"
    task.done = true
    task.success = success
    task.exit_code = exit_code
    task.message = success and (task.mode == "create" and _("Archive created successfully") or _("Archive extracted successfully")) or
        (command_err or _("Archive operation failed"))
    task.finished_at = current_timestamp()
    archive.write_state(task)
end

function archive.start_task(task)
    local nixio = require "nixio"
    local pid = nixio.fork()
    if not pid or pid < 0 then
        return nil, "fork archive task failed"
    end
    if pid == 0 then
        pcall(nixio.setsid)
        local ok, err = pcall(archive.run_task, task)
        if not ok then
            task.state = "failed"
            task.done = true
            task.success = false
            task.message = _("Archive operation failed")
            task.exit_code = -1
            task.finished_at = current_timestamp()
            hb_log(archive.log_file, "archive runtime error: " .. tostring(err))
            archive.write_state(task)
        end
        os.exit(0)
    end
    task.pid = pid
    task.state = "running"
    task.message = task.mode == "create" and _("Creating archive") or _("Extracting archive")
    archive.write_state(task)
    return pid
end

function archive.busy_response(current)
    write_json_status(409, "Conflict", {
        code = 1,
        message = _("Another archive task is already running"),
        data = archive.response(current)
    })
end

function archive.start_response(task)
    local nixio_fs = require "nixio.fs"
    clear_log()
    hb_log(archive.log_file, "==== Archive task start ====")
    if not archive.write_state(task) then
        write_json_status(500, "Archive Failed", { code = 1, message = _("Archive operation failed") })
        return
    end
    local pid, start_err = archive.start_task(task)
    if not pid then
        task.state = "failed"
        task.done = true
        task.success = false
        task.message = _("Archive operation failed")
        task.exit_code = -1
        task.finished_at = current_timestamp()
        archive.write_state(task)
        write_json_status(500, "Archive Failed", { code = 1, message = start_err or _("Archive operation failed") })
        return
    end
    write_json({ code = 0, message = "success", data = archive.response(task) })
end

local function harbor_file_base64_encode(data)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local output = {}
    local value = tostring(data or "")
    for index = 1, #value, 3 do
        local first = value:byte(index) or 0
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local packed = first * 65536 + (second or 0) * 256 + (third or 0)
        output[#output + 1] = chars:sub(math.floor(packed / 262144) + 1, math.floor(packed / 262144) + 1)
        output[#output + 1] = chars:sub(math.floor(packed / 4096) % 64 + 1, math.floor(packed / 4096) % 64 + 1)
        output[#output + 1] = second and chars:sub(math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1) or "="
        output[#output + 1] = third and chars:sub(packed % 64 + 1, packed % 64 + 1) or "="
    end
    return table.concat(output)
end

M.activate_nginx_web_server = activate_nginx_web_server
M.apk_package_installed = apk_package_installed
M.archive = archive
M.archive.busy_response = archive.busy_response
M.archive.create_command = archive.create_command
M.archive.detect_extract_format = archive.detect_extract_format
M.archive.ensure_extension = archive.ensure_extension
M.archive.extract_command = archive.extract_command
M.archive.file_name = archive.file_name
M.archive.read_state = archive.read_state
M.archive.response = archive.response
M.archive.run_shell = archive.run_shell
M.archive.run_task = archive.run_task
M.archive.source_size = archive.source_size
M.archive.source_size_estimate = archive.source_size_estimate
M.archive.start_response = archive.start_response
M.archive.start_task = archive.start_task
M.archive.strip_suffix = archive.strip_suffix
M.archive.task_id = archive.task_id
M.archive.write_state = archive.write_state
M.backup_config_file = backup_config_file
M.build_package_index_update_command = build_package_index_update_command
M.build_package_install_command = build_package_install_command
M.build_package_install_response = build_package_install_response
M.build_quick_access = build_quick_access
M.build_thumbnail_command = build_thumbnail_command
M.build_thumbnail_task_response = build_thumbnail_task_response
M.calculate_operation_space_margin = calculate_operation_space_margin
M.classify_preview = classify_preview
M.clean_log_value = clean_log_value
M.cleanup_stale_uploads = cleanup_stale_uploads
M.collect_thumbnail_images = collect_thumbnail_images
M.command_to_shell = command_to_shell
M.common_directory_entries = common_directory_entries
M.contains_mount = contains_mount
M.copy_regular_file = copy_regular_file
M.copy_tree = copy_tree
M.create_package_install_task = create_package_install_task
M.create_repository_install_task = create_repository_install_task
M.create_thumbnail_task = create_thumbnail_task
M.current_timestamp = current_timestamp
M.default_binary_read_kb = default_binary_read_kb
M.deny_system_operation = deny_system_operation
M.detect_apk_package_name = detect_apk_package_name
M.detect_nginx_installer = detect_nginx_installer
M.detect_package_installer = detect_package_installer
M.detect_web_server = detect_web_server
M.drive_name = drive_name
M.ensure_directory_space = ensure_directory_space
M.ensure_preference_section = ensure_preference_section
M.ensure_uhttpd_section = ensure_uhttpd_section
M.find_executable = find_executable
M.get_available_memory_kb = get_available_memory_kb
M.get_directory_available_bytes = get_directory_available_bytes
M.get_directory_space_info = get_directory_space_info
M.get_ext = get_ext
M.get_package_type = get_package_type
M.get_upload_directory = get_upload_directory
M.get_writable_directory = get_writable_directory
M.harbor_debug_log = harbor_debug_log
M.harbor_file_base64_encode = harbor_file_base64_encode
M.harbor_log_file = harbor_log_file
M.has_package_index_cache = has_package_index_cache
M.hb_log = hb_log
M.hex32 = hex32
M.hidden_mounts = hidden_mounts
M.image_mime_map = image_mime_map
M.insert_nginx_directive = insert_nginx_directive
M.insufficient_space_message = insufficient_space_message
M.is_child_path = is_child_path
M.is_fanchmwrt_system = is_fanchmwrt_system
M.is_hidden_file_name = is_hidden_file_name
M.is_system_path = is_system_path
M.join_path = join_path
M.list_directory = list_directory
M.list_drives = list_drives
M.list_root_folders = list_root_folders
M.max_binary_read_kb = max_binary_read_kb
M.max_binary_read_size = max_binary_read_size
M.mkdir_p = mkdir_p
M.nginx_configuration_options = nginx_configuration_options
M.nginx_insert_anchor = nginx_insert_anchor
M.nginx_package_name = nginx_package_name
M.nginx_template_file = nginx_template_file
M.normalize_home_dir = normalize_home_dir
M.normalize_integer_value = normalize_integer_value
M.normalize_nginx_body_size = normalize_nginx_body_size
M.normalize_path = normalize_path
M.normalize_port_number = normalize_port_number
M.normalize_preference_number = normalize_preference_number
M.normalize_timeout_value = normalize_timeout_value
M.normalize_window_dimension = normalize_window_dimension
M.operation_space_ratio = operation_space_ratio
M.opkg_required_feed_groups = opkg_required_feed_groups
M.package_ext_map = package_ext_map
M.package_index_cache_roots = package_index_cache_roots
M.package_install_log_file = package_install_log_file
M.package_install_log_limit = package_install_log_limit
M.package_install_state_file = package_install_state_file
M.parent_path = parent_path
M.parse_binary_number = parse_binary_number
M.parse_execute_result = parse_execute_result
M.parse_size = parse_size
M.parse_upload_names = parse_upload_names
M.pdf_mime_map = pdf_mime_map
M.preference_defaults = preference_defaults
M.preference_log = preference_log
M.preferences_log_file = preferences_log_file
M.read_json_file = read_json_file
M.read_log_file = read_log_file
M.read_mount_paths = read_mount_paths
M.read_nginx_form_preferences = read_nginx_form_preferences
M.read_nginx_preferences = read_nginx_preferences
M.read_package_install_state = read_package_install_state
M.read_preference_value = read_preference_value
M.read_preferences = read_preferences
M.read_thumbnail_task_state = read_thumbnail_task_state
M.read_ttyd_config = read_ttyd_config
M.read_ttyd_info = read_ttyd_info
M.read_uhttpd_form_preferences = read_uhttpd_form_preferences
M.read_uhttpd_preferences = read_uhttpd_preferences
M.read_uwsgi_form_preferences = read_uwsgi_form_preferences
M.read_uwsgi_preferences = read_uwsgi_preferences
M.remove_tree = remove_tree
M.replace_nginx_directive = replace_nginx_directive
M.restore_config_file = restore_config_file
M.run_logged_command = run_logged_command
M.run_package_install_task = run_package_install_task
M.run_thumbnail_task = run_thumbnail_task
M.save_basic_preferences = save_basic_preferences
M.save_last_directory = save_last_directory
M.save_show_line_numbers = save_show_line_numbers
M.save_nginx_configuration = save_nginx_configuration
M.save_uhttpd_configuration = save_uhttpd_configuration
M.save_uwsgi_configuration = save_uwsgi_configuration
M.save_window_preferences = save_window_preferences
M.schedule_nginx_restart = schedule_nginx_restart
M.schedule_uhttpd_restart = schedule_uhttpd_restart
M.schedule_uwsgi_restart = schedule_uwsgi_restart
M.set_nginx_directive = set_nginx_directive
M.set_status = set_status
M.shell_quote = shell_quote
M.stable_hash = stable_hash
M.start_package_install_task = start_package_install_task
M.start_thumbnail_task = start_thumbnail_task
M.system_folder_roots = system_folder_roots
M.system_operations_allowed = system_operations_allowed
M.task_process_running = task_process_running
M.terminal_package_name = terminal_package_name
M.test_nginx_configuration = test_nginx_configuration
M.text_ext_map = text_ext_map
M.thumbnail_available = thumbnail_available
M.thumbnail_cache_dir = thumbnail_cache_dir
M.thumbnail_cache_key = thumbnail_cache_key
M.thumbnail_cache_path = thumbnail_cache_path
M.thumbnail_cache_version = thumbnail_cache_version
M.thumbnail_memory_margin = thumbnail_memory_margin
M.thumbnail_size = thumbnail_size
M.thumbnail_task_log_file = thumbnail_task_log_file
M.thumbnail_task_log_limit = thumbnail_task_log_limit
M.thumbnail_task_state_file = thumbnail_task_state_file
M.to_boolean = to_boolean
M.tool_package_name = tool_package_name
M.truncate_log_text = truncate_log_text
M.uhttpd_network_timeout_default = uhttpd_network_timeout_default
M.uhttpd_script_timeout_default = uhttpd_script_timeout_default
M.uwsgi_config_file = uwsgi_config_file
M.uwsgi_configuration_options = uwsgi_configuration_options
M.uwsgi_preferences_changed = uwsgi_preferences_changed
M.valid_boolean_values = valid_boolean_values
M.valid_view_mode_values = valid_view_mode_values
M.validate_package_file = validate_package_file
M.validate_upload_name = validate_upload_name
M.validate_write_request = validate_write_request
M.video_mime_map = video_mime_map
M.video_now_ms = video_now_ms
M.utf8_valid = utf8_valid
M.write_json = write_json
M.write_json_file = write_json_file
M.write_json_status = write_json_status
M.write_package_install_state = write_package_install_state
M.write_plain_status = write_plain_status
M.write_thumbnail_task_state = write_thumbnail_task_state

return M
