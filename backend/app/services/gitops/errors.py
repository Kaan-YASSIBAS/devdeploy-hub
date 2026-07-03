class GitOpsWriterError(ValueError):
    """A safe internal GitOps writer error with a stable machine code."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message

    def __str__(self) -> str:
        return self.message
