class ServiceError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code


class AccessDenied(ServiceError):
    def __init__(self, message="Not in your scope", status=403):
        super().__init__(status, "unauthorized" if status == 401 else "forbidden", message)


class Conflict(ServiceError):
    def __init__(self, message, code="conflict"):
        super().__init__(409, code, message)


def invalid(message):
    return ServiceError(400, "invalid_request", message)
