.PHONY: build app test test-tools audit-public release-plan clean run icons

icons:
	./scripts/build-icons.sh

build:
	swift build

app:
	./scripts/build-app.sh

test:
	swift test

run: app
	open build/Tsundoku.app

clean:
	rm -rf .build build

test-tools:
	python3 -m unittest discover -s scripts/tests -v

audit-public:
	python3 scripts/privacy_audit.py --report build/privacy-report.json

release-plan:
	./scripts/release.sh plan
