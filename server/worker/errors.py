"""Classified pipeline failure types shared by the worker loop and the pipeline."""


class PipelineError(Exception):
    """Base class for classified pipeline failures with a stable public code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class RetryablePipelineError(PipelineError):
    """Transient failure; the job may be retried automatically (max twice)."""
