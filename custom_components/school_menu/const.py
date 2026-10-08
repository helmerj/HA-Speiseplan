DOMAIN = "school_menu"
DEFAULT_NAME = "School menu"
SINGLE_ENTRY_UNIQUE_ID = "school_menu_single_entry"
CONF_NAME = "name"
STORAGE_VERSION = 1
STORAGE_MINOR_VERSION = 1
STORAGE_KEY_PREFIX = "school_menu"
WEEKS_RETAINED = 4

NO_MENU_STATE = "none"
REASON_WEEKEND = "weekend"
REASON_NO_MENU = "no_menu"
STATE_MAX_LENGTH = 255

ATTR_WEEKDAY = "weekday"
ATTR_DATE = "date"
ATTR_MAIN = "main"
ATTR_SIDE = "side"
ATTR_DESSERT = "dessert"
ATTR_LINES = "lines"
ATTR_SOURCE_FILE = "source_file"
ATTR_INGESTED_AT = "ingested_at"
ATTR_REASON = "reason"
ATTR_WEEK = "week"
ATTR_SOURCE = "source"
ATTR_WEEKS_STORED = "weeks_stored"

GERMAN_WEEKDAYS = (
    "Montag",
    "Dienstag",
    "Mittwoch",
    "Donnerstag",
    "Freitag",
    "Samstag",
    "Sonntag",
)

SERVICE_IMPORT_PDF = "import_pdf"
SERVICE_CHECK_MAIL = "check_mail"
CHECK_MAIL_COOLDOWN_SECONDS = 60
BUTTON_CHECK_MAIL = "check_mail"
CONF_FILE_PATH = "file_path"
CONF_FILE_ID = "file_id"
CONF_WEEK_START = "week_start"
SOURCE_MANUAL = "manual"
SENSOR_TODAY = "today"
SENSOR_NEXT_SCHOOL_DAY = "next_school_day"
SENSOR_LAST_IMPORT = "last_import"
NOTIFICATION_ERROR_ID = "school_menu_import_error"
NOTIFICATION_OK_ID = "school_menu_import_ok"

CONF_HOST = "host"
CONF_PORT = "port"
CONF_USERNAME = "username"
CONF_PASSWORD = "password"
CONF_SSL = "ssl"
CONF_FOLDER = "folder"
CONF_SENDERS = "senders"
CONF_SUBJECT_FILTER = "subject_filter"
CONF_SCAN_INTERVAL_MINUTES = "scan_interval_minutes"

DEFAULT_PORT = 993
DEFAULT_SSL = True
DEFAULT_FOLDER = "INBOX"
DEFAULT_SUBJECT_FILTER = "Speiseplan"
DEFAULT_SENDERS = ("@annie-heuser.schule",)
LEGACY_DEFAULT_SUBJECT_FILTER = "Speiseplan KW"
LEGACY_DEFAULT_SENDERS = (
    "Maximilian.Stollberg@annie-heuser.schule",
    "Lena.Putzmann@annie-heuser.schule",
)
DEFAULT_SCAN_INTERVAL_MINUTES = 15
MIN_SCAN_INTERVAL_MINUTES = 5
SEARCH_WINDOW_DAYS = 14
FAILURES_BEFORE_NOTIFYING = 3
IMAP_COMMAND_TIMEOUT_SECONDS = 30
IMAP_POLL_TIMEOUT_SECONDS = 120
IMAP_TEARDOWN_TIMEOUT_SECONDS = 5
REASON_FEWER_DAYS = "fewer_days"

SOURCE_IMAP = "imap"
NOTIFICATION_IMAP_ID = "school_menu_imap_error"

UPDATE_VERSION = "version"
UPDATE_TITLE = "School Menu"
UPDATE_CHECK_HOURS = 6
GITHUB_REPOSITORY = "helmerj/HA-Speiseplan"
GITHUB_REPOSITORY_ID = 1389147095
GITHUB_LATEST_RELEASE_URL = f"https://api.github.com/repos/{GITHUB_REPOSITORY}/releases/latest"
GITHUB_TIMEOUT_SECONDS = 10
GITHUB_HEADERS = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "school-menu-home-assistant",
}
HACS_DOMAIN = "hacs"
NOTIFICATION_UPDATE_ID = "school_menu_update"
