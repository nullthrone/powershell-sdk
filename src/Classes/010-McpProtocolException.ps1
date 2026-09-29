# JSON-RPC errors as exceptions. The router and the handlers throw McpProtocolException; the dispatcher turns it
# into an error response with Code as error.code, Message as error.message and Data (optional) as error.data.
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

# Control flow of multi-round-trip requests (MRTR): Request-McpElicitation, Request-McpSampling and
# Request-McpRoot throw it when the answer to an input request is not there yet. It derives from
# McpProtocolException so that the handler wrappers pass it through unchanged; the worker turns it into an
# InputRequiredResult with the pending input requests and a signed requestState.
[NoRunspaceAffinity()]
class McpInputRequiredException : McpProtocolException {
    [System.Collections.Specialized.OrderedDictionary] $InputRequests

    McpInputRequiredException([System.Collections.Specialized.OrderedDictionary] $inputRequests) : base(-32603, 'The handler requires input from the client; input requests are only answered in tools/call, prompts/get and resources/read.') {
        $this.InputRequests = $inputRequests
    }
}

# A URI that names no resource. Revision 2026-07-28 answers it with -32602 and data.uri (SEP-2164); the legacy
# revisions use -32002. The subclass marks the error so that the era-aware serialization can pick the code.
[NoRunspaceAffinity()]
class McpResourceNotFoundException : McpProtocolException {
    McpResourceNotFoundException([string] $uri) : base(-32602, 'Resource not found', [ordered]@{ uri = $uri }) {
    }
}
