from __future__ import annotations

import sys
import urllib.error
import urllib.parse
import urllib.request


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ssltruster_probe.py URL", file=sys.stderr)
        return 2
    request = urllib.request.Request(
        sys.argv[1],
        headers={"User-Agent": "EAP-SSLTruster/1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            if urllib.parse.urlsplit(response.geturl()).scheme.lower() != "https":
                raise RuntimeError("redirect to a non-HTTPS URL")
            print(response.status)
    except urllib.error.HTTPError as exc:
        # An HTTP response proves that DNS, proxy and TLS negotiation worked.
        if urllib.parse.urlsplit(exc.geturl()).scheme.lower() != "https":
            print("redirect to a non-HTTPS URL", file=sys.stderr)
            return 1
        print(exc.code)
    except Exception as exc:
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
