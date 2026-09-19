# Severity of a log message (RFC 5424), matching the LoggingLevel definition of schema.json in every
# supported revision. Wire names are the lowercase member names. The members are declared from least to most
# severe, so their implicit values (Debug = 0 ... Emergency = 7) let "at least level X" filters compare enum
# values. tests/Unit/Enums.Tests.ps1 checks the member set and the ordering against the vendored schemas.
enum McpLoggingLevel {
    Debug
    Info
    Notice
    Warning
    Error
    Critical
    Alert
    Emergency
}
