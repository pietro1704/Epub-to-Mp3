"""Bind extracted legacy server functions to their actual facade module."""

import inspect
from functools import wraps


def bind_server_function(implementation, runtime):
    """Preserve route introspection while resolving facade patches at each call."""
    if inspect.iscoroutinefunction(implementation):
        @wraps(implementation)
        async def bound(*args, **kwargs):
            return await implementation(runtime, *args, **kwargs)
    else:
        @wraps(implementation)
        def bound(*args, **kwargs):
            return implementation(runtime, *args, **kwargs)

    signature = inspect.signature(implementation, eval_str=True)
    bound.__signature__ = signature.replace(parameters=list(signature.parameters.values())[1:])
    bound.__annotations__ = {
        name: parameter.annotation
        for name, parameter in bound.__signature__.parameters.items()
        if parameter.annotation is not inspect.Parameter.empty
    }
    if signature.return_annotation is not inspect.Signature.empty:
        bound.__annotations__["return"] = signature.return_annotation
    bound.__module__ = runtime.__name__
    return bound
