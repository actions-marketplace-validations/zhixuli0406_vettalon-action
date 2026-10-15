# Test fixture

Deliberately vulnerable files used by `.github/workflows/test.yml` to check
that the action finds issues and writes SARIF. None of this code is meant to
run, and the credential in `settings.py` is a random string, not a real key.
