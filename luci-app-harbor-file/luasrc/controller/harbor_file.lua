module("luci.controller.harbor_file", package.seeall)

_ = require("luci.i18n").translate

local fs = require "luci.controller.harbor_file.fs"
local prefs = require "luci.controller.harbor_file.prefs"
local tools = require "luci.controller.harbor_file.tools"

api_archive_create_start = fs.api_archive_create_start
api_archive_extract_start = fs.api_archive_extract_start
api_archive_status = fs.api_archive_status
api_batch_check = fs.api_batch_check
api_batch_copy = fs.api_batch_copy
api_batch_delete = fs.api_batch_delete
api_batch_move = fs.api_batch_move
api_chmod = fs.api_chmod
api_copy = fs.api_copy
api_create_directory = fs.api_create_directory
api_create_file = fs.api_create_file
api_delete = fs.api_delete
api_detect_type = fs.api_detect_type
api_download = fs.api_download
api_image = fs.api_image
api_list = fs.api_list
api_move = fs.api_move
api_navigation = fs.api_navigation
api_nginx_install_start = tools.api_nginx_install_start
api_package_install_start = tools.api_package_install_start
api_package_install_status = tools.api_package_install_status
api_pdf = fs.api_pdf
api_preferences = prefs.api_preferences
api_read_binary = fs.api_read_binary
api_read_editor_file = fs.api_read_editor_file
api_read_text = fs.api_read_text
api_rename = fs.api_rename
api_save_editor_upload = fs.api_save_editor_upload
api_save_preferences = prefs.api_save_preferences
api_save_last_directory = prefs.api_save_last_directory
api_save_show_line_numbers = prefs.api_save_show_line_numbers
api_save_text = fs.api_save_text
api_terminal_info = tools.api_terminal_info
api_terminal_tool_install_start = tools.api_terminal_tool_install_start
api_thumbnail = fs.api_thumbnail
api_thumbnail_generate_start = tools.api_thumbnail_generate_start
api_thumbnail_generate_status = tools.api_thumbnail_generate_status
api_thumbnail_tool_install_start = tools.api_thumbnail_tool_install_start
api_tool_install_start = tools.api_tool_install_start
api_upload = fs.api_upload
api_upload_check = fs.api_upload_check
api_video = fs.api_video
api_video_check = fs.api_video_check

function index()
	local nixio_fs = require "nixio.fs"
    if nixio_fs.access("/etc/fwx_release") then
        entry({"admin", "fwx_harbor_file"}, template("harbor_file/index"), _("File management"), 16).dependent = true
    else
        entry({"admin", "harbor_file"}, alias("admin", "system", "harbor_file"), nil).leaf = true
        entry({"admin", "system", "harbor_file"}, template("harbor_file/index"), _("Harbor File"), 90).dependent = true
    end
    entry({"admin", "local_fs", "navigation"}, call("api_navigation"), nil).leaf = true
    entry({"admin", "local_fs", "terminal_info"}, call("api_terminal_info"), nil).leaf = true
    entry({"admin", "local_fs", "preferences"}, call("api_preferences"), nil).leaf = true
    entry({"admin", "local_fs", "save_preferences"}, call("api_save_preferences"), nil).leaf = true
    entry({"admin", "local_fs", "read_editor_file"}, call("api_read_editor_file"), nil).leaf = true
    entry({"admin", "local_fs", "save_editor_upload"}, call("api_save_editor_upload"), nil).leaf = true
    entry({"admin", "local_fs", "nginx_install_start"}, call("api_nginx_install_start"), nil).leaf = true
    entry({"admin", "local_fs", "list"}, call("api_list"), nil).leaf = true
    entry({"admin", "local_fs", "download"}, call("api_download"), nil).leaf = true
    entry({"admin", "local_fs", "read_text"}, call("api_read_text"), nil).leaf = true
    entry({"admin", "local_fs", "read_binary"}, call("api_read_binary"), nil).leaf = true
    entry({"admin", "local_fs", "save_text"}, call("api_save_text"), nil).leaf = true
    entry({"admin", "local_fs", "image"}, call("api_image"), nil).leaf = true
    entry({"admin", "local_fs", "thumbnail"}, call("api_thumbnail"), nil).leaf = true
    entry({"admin", "local_fs", "thumbnail_generate_start"}, call("api_thumbnail_generate_start"), nil).leaf = true
    entry({"admin", "local_fs", "thumbnail_generate_status"}, call("api_thumbnail_generate_status"), nil).leaf = true
    entry({"admin", "local_fs", "thumbnail_tool_install_start"}, call("api_thumbnail_tool_install_start"), nil).leaf = true
    entry({"admin", "local_fs", "terminal_tool_install_start"}, call("api_terminal_tool_install_start"), nil).leaf = true
    entry({"admin", "local_fs", "tool_install_start"}, call("api_tool_install_start"), nil).leaf = true
    entry({"admin", "local_fs", "pdf"}, call("api_pdf"), nil).leaf = true
    entry({"admin", "local_fs", "video"}, call("api_video"), nil).leaf = true
    entry({"admin", "local_fs", "video_check"}, call("api_video_check"), nil).leaf = true
    entry({"admin", "local_fs", "upload_check"}, call("api_upload_check"), nil).leaf = true
    entry({"admin", "local_fs", "upload"}, call("api_upload"), nil).leaf = true
    entry({"admin", "local_fs", "create_directory"}, call("api_create_directory"), nil).leaf = true
    entry({"admin", "local_fs", "create_file"}, call("api_create_file"), nil).leaf = true
    entry({"admin", "local_fs", "rename"}, call("api_rename"), nil).leaf = true
    entry({"admin", "local_fs", "delete"}, call("api_delete"), nil).leaf = true
    entry({"admin", "local_fs", "copy"}, call("api_copy"), nil).leaf = true
    entry({"admin", "local_fs", "move"}, call("api_move"), nil).leaf = true
    entry({"admin", "local_fs", "batch_copy"}, call("api_batch_copy"), nil).leaf = true
    entry({"admin", "local_fs", "batch_move"}, call("api_batch_move"), nil).leaf = true
    entry({"admin", "local_fs", "batch_delete"}, call("api_batch_delete"), nil).leaf = true
    entry({"admin", "local_fs", "archive_create_start"}, call("api_archive_create_start"), nil).leaf = true
    entry({"admin", "local_fs", "archive_extract_start"}, call("api_archive_extract_start"), nil).leaf = true
    entry({"admin", "local_fs", "archive_status"}, call("api_archive_status"), nil).leaf = true
    entry({"admin", "local_fs", "package_install_start"}, call("api_package_install_start"), nil).leaf = true
    entry({"admin", "local_fs", "package_install_status"}, call("api_package_install_status"), nil).leaf = true
    entry({"admin", "local_fs", "chmod"}, call("api_chmod"), nil).leaf = true
    entry({"admin", "local_fs", "batch_check"}, call("api_batch_check"), nil).leaf = true
    entry({"admin", "local_fs", "detect_type"}, call("api_detect_type"), nil).leaf = true
    entry({"admin", "local_fs", "save_last_directory"}, call("api_save_last_directory"), nil).leaf = true
    entry({"admin", "local_fs", "save_show_line_numbers"}, call("api_save_show_line_numbers"), nil).leaf = true
end

