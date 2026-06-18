
pub const Status = enum(u10) {
    ok = 200,
    created = 201,
    no_content = 204,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    request_timeout = 408,
    conflict = 409,
    entity_too_large = 413,
    too_many_requests = 429,
    internal_server_error = 500,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,

    
    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .no_content => "No Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .entity_too_large => "Entity Too Large",
            .too_many_requests => "Too Many Requests",
            .internal_server_error => "Internal Server Error",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
        };
    }
};
