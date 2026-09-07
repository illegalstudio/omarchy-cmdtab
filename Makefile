.PHONY: check release test validate

NODE ?= node
OMARCHY ?= omarchy
PYTHON ?= python3

check: validate test

validate:
	@$(PYTHON) -m json.tool manifest.json >/dev/null
	@$(OMARCHY) plugin validate .

test:
	@$(NODE) tests/switcher.test.js

release:
	@scripts/release.sh
