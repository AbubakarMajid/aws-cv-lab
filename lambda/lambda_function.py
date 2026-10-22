"""CV site served from a private S3 bucket through a Lambda function URL.

Bucket and prefix come from the BUCKET and PREFIX environment variables.
Credentials come from the function's execution role (no access keys).
Every request writes exactly one JSON log line: fn, path, status, ms.
"""
import base64
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"]
FUNCTION_NAME = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "unknown")

s3 = boto3.client("s3")  # created once per container, reused across requests

# path -> (S3 key under PREFIX, content type, is_binary)
ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8", False),
    "/index.html": ("index.html", "text/html; charset=utf-8", False),
    "/style.css": ("style.css", "text/css; charset=utf-8", False),
    "/cv.pdf": ("cv.pdf", "application/pdf", True),
}

NOT_FOUND_PAGE = (
    "<!DOCTYPE html><html><head><meta charset='utf-8'><title>404 Not Found</title></head>"
    "<body><h1>404 - Not Found</h1><p>That page does not exist. "
    "<a href='/'>Go to the CV</a>.</p></body></html>"
)


def _response(status, body, content_type, extra_headers=None, is_base64=False):
    headers = {"Content-Type": content_type}
    if extra_headers:
        headers.update(extra_headers)
    return {
        "statusCode": status,
        "headers": headers,
        "body": body,
        "isBase64Encoded": is_base64,
    }


def _serve(path):
    route = ROUTES.get(path)
    if route is None:
        return _response(404, NOT_FOUND_PAGE, "text/html; charset=utf-8")

    key, content_type, is_binary = route
    try:
        data = s3.get_object(Bucket=BUCKET, Key=PREFIX + key)["Body"].read()
    except ClientError as err:
        # Keep one log line per request: the error code is added to it in handler().
        _serve.last_error = err.response["Error"]["Code"]
        return _response(502, "<h1>502 - could not read the CV from storage</h1>", "text/html; charset=utf-8")

    if is_binary:
        return _response(200, base64.b64encode(data).decode("ascii"), content_type, is_base64=True)

    text = data.decode("utf-8")
    if key == "index.html":
        text = text.replace("{{HOSTED_ON}}", f"Lambda {FUNCTION_NAME}")
        return _response(200, text, content_type, {"Cache-Control": "public, max-age=60"})
    return _response(200, text, content_type)


def handler(event, context):
    start = time.perf_counter()
    path = event.get("rawPath") or "/"
    status = 500
    _serve.last_error = None
    try:
        resp = _serve(path)
        status = resp["statusCode"]
        return resp
    finally:
        ms = round((time.perf_counter() - start) * 1000, 1)
        line = {"fn": FUNCTION_NAME, "path": path, "status": status, "ms": ms}
        if _serve.last_error:
            line["error"] = _serve.last_error
        print(json.dumps(line))
