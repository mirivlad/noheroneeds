class_name GameInfo
## Version of the game build. Stored in worlds and profiles for diagnostics;
## compatibility is decided by schema and codec versions, not by this string.

static var VERSION: String = String(ProjectSettings.get_setting("application/config/version", "dev"))
