## account.gd -- Autoload "Account": sign-in state for online play.
##
## Talks to the matchmaking API (/auth/register, /auth/login, /auth/me, /auth/logout). Only the
## session token and username are stored (user://account.cfg) - never the password.
extends Node

signal changed                                   # signed in / out
signal request_done(ok: bool, message: String)   # result of sign_in / create_account / verify

const PATH: String = "user://account.cfg"

var username: String = ""
var token: String = ""
var api: String = ""


## Run from the Godot editor (several test windows share one user folder), the session stays in memory
## so each window keeps its own account and signing out in one cannot affect another.
static func _persists() -> bool:
	return not OS.has_feature("editor")


func _ready() -> void:
	if not _persists():
		return
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		username = str(cfg.get_value("session", "username", ""))
		token = str(cfg.get_value("session", "token", ""))
		api = str(cfg.get_value("session", "api", ""))


func is_signed_in() -> bool:
	return not token.is_empty() and not username.is_empty()


func auth_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + token])


## Returns an error message, or "" when the credentials look acceptable.
static func validate(user: String, password: String) -> String:
	var rx := RegEx.new()
	rx.compile("^[A-Za-z0-9_]{3,16}$")
	if rx.search(user) == null:
		return "Name: 3-16 letters, digits or underscore."
	if password.length() < 8:
		return "Password: at least 8 characters."
	return ""


func sign_in(api_url: String, user: String, password: String) -> void:
	_auth("/auth/login", api_url, user, password)


func create_account(api_url: String, user: String, password: String) -> void:
	_auth("/auth/register", api_url, user, password)


func sign_out() -> void:
	if is_signed_in() and not api.is_empty():
		var h := HTTPRequest.new()
		add_child(h)
		h.request_completed.connect(func(_r: int, _c: int, _h: PackedStringArray, _b: PackedByteArray) -> void: h.queue_free())
		h.request(api + "/auth/logout", auth_headers(), HTTPClient.METHOD_POST, "{}")
	clear_session()


func clear_session() -> void:
	username = ""
	token = ""
	_save()
	changed.emit()


## Checks the stored token is still valid; signs out silently if the server rejects it.
func verify(api_url: String) -> void:
	if not is_signed_in():
		request_done.emit(false, "")
		return
	var h := HTTPRequest.new()
	h.timeout = 8.0
	add_child(h)
	h.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		h.queue_free()
		if code == 200:
			request_done.emit(true, "")
		elif code == 401:
			clear_session()
			request_done.emit(false, "Your session expired - please sign in again.")
		else:
			request_done.emit(true, "")  # server unreachable: keep the session, matchmaking will report it
	)
	if h.request(_clean(api_url) + "/auth/me", auth_headers()) != OK:
		h.queue_free()
		request_done.emit(true, "")


func _auth(path: String, api_url: String, user: String, password: String) -> void:
	var problem := validate(user, password)
	if not problem.is_empty():
		request_done.emit(false, problem)
		return
	var base := _clean(api_url)
	var h := HTTPRequest.new()
	h.timeout = 10.0
	add_child(h)
	h.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		h.queue_free()
		var data = JSON.parse_string(body.get_string_from_utf8())
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and typeof(data) == TYPE_DICTIONARY and data.has("token"):
			username = str(data["username"])
			token = str(data["token"])
			api = base
			_save()
			changed.emit()
			request_done.emit(true, "")
		elif result != HTTPRequest.RESULT_SUCCESS:
			request_done.emit(false, "The server cannot be reached.")
		else:
			request_done.emit(false, _error_text(code, data))
	)
	var err := h.request(base + path, ["Content-Type: application/json"], HTTPClient.METHOD_POST,
		JSON.stringify({"username": user, "password": password}))
	if err != OK:
		h.queue_free()
		request_done.emit(false, "The server address looks invalid.")


func _error_text(code: int, data) -> String:
	if typeof(data) == TYPE_DICTIONARY and data.has("detail"):
		var d = data["detail"]
		if typeof(d) == TYPE_STRING:
			return d
		if typeof(d) == TYPE_ARRAY and not d.is_empty():
			return "Please check the name and password."
	return "Request failed (HTTP %d)." % code


func _clean(url: String) -> String:
	return clean_url(url)


## Tidies a pasted server address: spaces, trailing "/" or "." (e.g. copied from the end of a sentence).
static func clean_url(url: String) -> String:
	var u := url.strip_edges()
	while u.ends_with("/") or u.ends_with(".") or u.ends_with(","):
		u = u.left(u.length() - 1)
	return u if not u.is_empty() else "http://127.0.0.1:8000"


func _save() -> void:
	if not _persists():
		return
	var cfg := ConfigFile.new()
	cfg.set_value("session", "username", username)
	cfg.set_value("session", "token", token)
	cfg.set_value("session", "api", api)
	cfg.save(PATH)
