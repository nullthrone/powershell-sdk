# A JSON-RPC error as an exception. The router and the handlers throw it; the dispatcher turns it into an
# error response with Code as error.code, Message as error.message and Data (optional) as error.data.
[NoRunspaceAffinity()]
class McpProtocolException : System.Exception {
    [int] $Code
    [object] $Data

    McpProtocolException([int] $code, [string] $message) : base($message) {
        $this.Code = $code
    }

    McpProtocolException([int] $code, [string] $message, [object] $data) : base($message) {
        $this.Code = $code
        $this.Data = $data
    }
}
